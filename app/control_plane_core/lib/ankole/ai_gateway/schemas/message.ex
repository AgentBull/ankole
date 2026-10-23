defmodule Ankole.AIGateway.Schemas.Message do
  @moduledoc "Response facts, checkpoints, and tool journals with one terminal-state owner."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AIGateway,
    extensions: [AshStateMachine, AshJsonApi.Resource]

  require Ash.Expr
  import Ash.Expr, only: [arg: 1]
  alias Ankole.AIGateway.{ResponseCommit, StatefulResponses}

  @merge_metadata Ash.Expr.expr(
                    fragment("COALESCE(?, '{}'::jsonb) || ?::jsonb", metadata, ^arg(:metadata))
                  )
  @append_output Ash.Expr.expr(fragment("? || to_jsonb(?::jsonb[])", content, ^arg(:output)))

  json_api do
    type("ai_gateway_message")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :subject_uid,
      :conversation_id,
      :type,
      :status,
      :previous_message_id,
      :content,
      :metadata,
      :inserted_at,
      :updated_at
    ])
  end

  postgres do
    table("ai_gateway_messages")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(journal_key: "ai_gateway_messages_tool_result_journal_key_index")
    identity_wheres_to_sql(journal_key: "metadata ? 'tool_result_idempotency_key'")
    calculations_to_sql(journal_key: "metadata->>'tool_result_idempotency_key'")

    foreign_key_names(
      subject_uid: "ai_gateway_messages_subject_uid_fkey",
      conversation_id: "ai_gateway_messages_conversation_id_fkey"
    )

    check_constraints do
      check_constraint(:type, "ai_gateway_messages_type_check")
      check_constraint(:status, "ai_gateway_messages_status_check")
      check_constraint(:content, "ai_gateway_messages_content_array")
      check_constraint(:metadata, "ai_gateway_messages_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:subject_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false, public?: true)

    attribute(:type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:message, :checkpoint]],
      public?: true
    )

    attribute(:previous_message_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:content, Ankole.Ash.Types.JSONList,
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      constraints: [allow_datetime?: true],
      public?: true
    )

    create_timestamp(:inserted_at, type: :utc_datetime_usec, public?: true)
    update_timestamp(:updated_at, type: :utc_datetime_usec, public?: true)
  end

  calculations do
    calculate(
      :journal_key,
      :string,
      expr(fragment("?->>'tool_result_idempotency_key'", metadata))
    )

    calculate(:oidc_client_id, :string, expr(fragment("?->>'oidc_client_id'", metadata)))
  end

  identities do
    identity(:journal_key, [:journal_key],
      all_tenants?: true,
      where: expr(fragment("? \\? 'tool_result_idempotency_key'", metadata))
    )
  end

  state_machine do
    state_attribute(:status)
    initial_states([:generating, :complete, :error])
    default_initial_state(:generating)

    transitions do
      transition(:complete, from: :generating, to: :complete)
      transition(:fail, from: :generating, to: :error)
      transition(:retract, from: [:generating, :complete], to: :retracted)
    end
  end

  actions do
    defaults([:read])

    # The operator console reads the messages of one conversation in order.
    read :console_list do
      argument(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      filter(expr(conversation_id == ^arg(:conversation_id)))
      pagination(keyset?: true, default_limit: 200, max_page_size: 500, required?: false)
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
    end

    create :start do
      accept([:subject_uid, :conversation_id, :previous_message_id, :content, :metadata])
      change(set_attribute(:type, :message))
    end

    create :checkpoint do
      accept([:id, :subject_uid, :conversation_id, :previous_message_id, :content, :metadata])
      change(set_attribute(:type, :checkpoint))
      change(set_attribute(:status, :complete))

      validate(
        fn changeset, _context ->
          validate_checkpoint(Ash.Changeset.get_attribute(changeset, :content))
        end,
        only_when_valid?: true
      )
    end

    create_if_absent :journal, upsert_fields: [:metadata] do
      accept([:id, :subject_uid, :conversation_id, :previous_message_id, :content, :metadata])
      argument(:journal_key, :string)
      change(set_attribute(:type, :message))
      change(set_attribute(:status, :complete))
      validate(fn changeset, _context -> validate_journal_key(changeset) end)
      upsert_identity(:journal_key)
    end

    create_if_absent :quarantine, upsert_fields: [:metadata] do
      accept([:id, :subject_uid, :conversation_id, :previous_message_id, :content, :metadata])
      argument(:journal_key, :string)
      change(set_attribute(:type, :message))
      change(set_attribute(:status, :error))
      validate(fn changeset, _context -> validate_journal_key(changeset) end)
      upsert_identity(:journal_key)
    end

    update :heartbeat do
      require_atomic?(true)
      accept([])

      argument(:metadata, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        default: %{},
        constraints: [allow_datetime?: true]
      )

      argument(:now, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(status == :generating)))
      change(atomic_update(:metadata, @merge_metadata))
      change(set_attribute(:updated_at, arg(:now)))
    end

    update :record_progress do
      require_atomic?(true)
      accept([])

      argument(:metadata, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        constraints: [allow_datetime?: true]
      )

      change(filter(expr(status == :generating)))
      change(atomic_update(:metadata, @merge_metadata))
      change(atomic_update(:updated_at, expr(updated_at)))
    end

    update :update_context do
      require_atomic?(true)
      accept([:previous_message_id])

      argument(:metadata, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        default: %{},
        constraints: [allow_datetime?: true]
      )

      argument(:drop_keys, {:array, :string}, allow_nil?: false, default: [])
      change(filter(expr(status == :generating)))

      change(
        atomic_update(
          :metadata,
          expr(
            fragment(
              "(COALESCE(?, '{}'::jsonb) - ?::text[]) || ?::jsonb",
              metadata,
              ^arg(:drop_keys),
              ^arg(:metadata)
            )
          )
        )
      )
    end

    update :complete do
      require_atomic?(true)
      accept([])
      argument(:output, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])

      argument(:metadata, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        default: %{},
        constraints: [allow_datetime?: true]
      )

      change(transition_state(:complete))
      change(atomic_update(:content, @append_output))
      change(atomic_update(:metadata, @merge_metadata))
    end

    update :fail do
      require_atomic?(true)
      accept([])
      argument(:output, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])

      argument(:metadata, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        default: %{},
        constraints: [allow_datetime?: true]
      )

      argument(:now, :utc_datetime_usec,
        allow_nil?: false,
        default: &DateTime.utc_now/0
      )

      change(transition_state(:error))
      change(atomic_update(:content, @append_output))
      change(atomic_update(:metadata, @merge_metadata))
      change(set_attribute(:updated_at, arg(:now)))
    end

    update :retract do
      require_atomic?(true)
      accept([])

      argument(:metadata, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        constraints: [allow_datetime?: true]
      )

      argument(:now, :utc_datetime_usec,
        allow_nil?: false,
        default: &DateTime.utc_now/0
      )

      change(transition_state(:retracted))
      change(atomic_update(:metadata, @merge_metadata))
      change(set_attribute(:updated_at, arg(:now)))
    end

    destroy :remove_suffix do
      require_atomic?(true)
      change(filter(expr(type == :message and status == :complete)))
    end

    action :renew_lease, :term do
      argument(:subject_uid, :string, allow_nil?: false)
      argument(:message_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:metadata, :map, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> ResponseCommit.renew_lease() |> Ankole.Errors.wrap()
      end)
    end

    action :fail_generating, :term do
      argument(:subject_uid, :string, allow_nil?: false)
      argument(:message_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:error_details, :map, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)
      after_commit({ResponseCommit, :publish_committed})

      run(fn input, _context ->
        input.arguments |> ResponseCommit.fail_generating() |> Ankole.Errors.wrap()
      end)
    end

    action :reconcile_orphan, :term do
      argument(:message_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)
      argument(:force, :boolean, allow_nil?: false, default: false)
      after_commit({ResponseCommit, :publish_committed})

      run(fn input, _context ->
        input.arguments |> ResponseCommit.reconcile_orphan() |> Ankole.Errors.wrap()
      end)
    end

    action :commit_terminal, :term do
      argument(:message_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:transition, :atom, allow_nil?: false, constraints: [one_of: [:complete, :fail]])
      argument(:output, :term, allow_nil?: false)
      argument(:metadata, :map, allow_nil?: false)
      after_commit({ResponseCommit, :publish_committed})

      run(fn input, _context ->
        input.arguments |> ResponseCommit.commit_terminal_locked() |> Ankole.Errors.wrap()
      end)
    end

    action :admit_run, :term do
      argument(:subject_uid, :string, allow_nil?: false)
      argument(:selector, :term, allow_nil?: false)
      argument(:compaction, :term)
      argument(:content, :term, allow_nil?: false)
      argument(:metadata, :map, allow_nil?: false)
      argument(:authorize_run, :term, allow_nil?: false)
      argument(:record_response, :term, allow_nil?: false)
      after_commit({ResponseCommit, :publish_committed})

      run(fn input, _context ->
        input.arguments |> StatefulResponses.admit_run() |> Ankole.Errors.wrap()
      end)
    end

    action :install_recovery_checkpoint, :term do
      argument(:message, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])
      argument(:artifact_attrs, :map, allow_nil?: false)
      argument(:checkpoint_metadata, :map, allow_nil?: false)
      argument(:injection, :map, allow_nil?: false)

      run(fn input, _context ->
        input.arguments |> StatefulResponses.install_recovery_checkpoint() |> Ankole.Errors.wrap()
      end)
    end
  end

  validations do
    validate(
      fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :type) == :message and
             Enum.any?(Ash.Changeset.get_attribute(changeset, :content) || [], fn
               %{"type" => type} when type in ["compaction", "compaction_artifact"] -> true
               _item -> false
             end),
           do:
             {:error,
              field: :content, message: "must not include compaction items or artifact refs"},
           else: :ok
      end,
      on: [:create],
      only_when_valid?: true
    )
  end

  defp validate_journal_key(changeset) do
    if Ash.Changeset.get_argument(changeset, :journal_key) ==
         (Ash.Changeset.get_attribute(changeset, :metadata) || %{})["tool_result_idempotency_key"],
       do: :ok,
       else: {:error, field: :metadata, message: "must match its journal identity"}
  end

  defp validate_checkpoint([%{"type" => "compaction_artifact", "id" => "cmp_" <> uuid}]) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> :ok
      :error -> {:error, field: :content, message: "must reference a valid compaction artifact"}
    end
  end

  defp validate_checkpoint(_content),
    do: {:error, field: :content, message: "must include exactly one compaction artifact ref"}

  @type t :: %__MODULE__{}
end
