defmodule Ankole.Conversations.Delivery.Intent do
  @moduledoc """
  Durable protocol operation for an external Conversation.

  Pending rows have a bounded attempt budget. A timestamp fences an in-flight
  attempt. Sent rows reference the public Message recorded in the same commit.
  Failed and expired rows stop; unknown sends require explicit operator action.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Conversations.Domain,
    extensions: [AshStateMachine]

  @type t :: %__MODULE__{}

  postgres do
    table("deliveries")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "deliveries_agent_uid_fkey"},
      {:conversation_id, "deliveries_conversation_id_fkey"},
      {:created_message_id, "deliveries_created_message_id_fkey"},
      {:target_message_id, "deliveries_target_message_id_fkey"},
      {:reply_to_message_id, "deliveries_reply_to_message_id_fkey"}
    ])

    unique_index_names([{[:agent_uid, :binding_name, :outbound_key], "deliveries_pkey"}])

    check_constraints do
      check_constraint(:recovery_status, "deliveries_recovery_status_valid")
      check_constraint(:recovery_status, "deliveries_recovery_status_delivery")
      check_constraint(:recovery_reason, "deliveries_recovery_reason_paired")
      check_constraint(:possible_duplicate_notice, "deliveries_duplicate_notice_requires_flag")
      check_constraint(:recovery_state, "deliveries_recovery_state_adapter_only")
      check_constraint(:recovery_state, "deliveries_recovery_state_object")
      check_constraint(:payload, "deliveries_payload_object")
      check_constraint(:last_error, "deliveries_last_error_object")
      check_constraint(:attempt_count, "deliveries_attempts_non_negative")
      check_constraint(:delivery_class, "deliveries_delivery_class_check")
    end
  end

  attributes do
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:binding_name, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:outbound_key, :string, primary_key?: true, allow_nil?: false, public?: true)

    attribute(:delivery_class, Ankole.Ash.Types.State,
      constraints: [one_of: [:generic, :durable_ai_reply]],
      public?: true,
      allow_nil?: false,
      default: :generic
    )

    attribute(:operation, Ankole.Ash.Types.State,
      constraints: [
        one_of: [:post, :reply, :edit, :delete, :reaction_add, :reaction_remove, :divider, :card]
      ],
      public?: true,
      allow_nil?: false
    )

    attribute(:status, Ankole.Ash.Types.State,
      constraints: [one_of: [:pending, :sent, :failed, :expired, :unknown]],
      public?: true,
      allow_nil?: false,
      default: :pending
    )

    attribute(:recovery_status, Ankole.Ash.Types.State,
      constraints: [one_of: [:blocked, :permanent, :exhausted]],
      public?: true
    )

    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:created_message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:target_message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:reply_to_message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:source_signal_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:ai_message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:provider_thread_id, :string, public?: true)
    attribute(:reply_to_provider_message_id, :string, public?: true)
    attribute(:target_provider_message_id, :string, public?: true)
    attribute(:created_provider_message_id, :string, public?: true)
    attribute(:fallback_visible_text, :string, public?: true)
    attribute(:idempotency_key, :string, public?: true)
    attribute(:recovery_reason, :string, public?: true)
    attribute(:possible_duplicate_notice, :string, public?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true)
    attribute(:platform_send_started_at, :utc_datetime_usec, public?: true)
    attribute(:next_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:payload, Ankole.Ash.Types.JSONMap, default: %{}, allow_nil?: false, public?: true)

    attribute(:last_error, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true,
      constraints: [allow_datetime?: true]
    )

    attribute(:recovery_state, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true,
      constraints: [allow_datetime?: true]
    )

    attribute(:attempt_count, :integer, default: 0, allow_nil?: false, constraints: [min: 0])

    attribute(:max_attempts, :integer,
      default: 10,
      allow_nil?: false,
      constraints: [min: 1],
      public?: true
    )

    attribute(:possible_duplicate, :boolean, default: false, allow_nil?: false, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  changes do
    change(
      fn changeset, _context ->
        Ash.Changeset.filter(changeset,
          status: changeset.data.status,
          attempt_count: changeset.data.attempt_count
        )
      end,
      on: [:update]
    )
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending, :failed])
    default_initial_state(:pending)

    transitions do
      transition(:start_attempt, from: [:pending, :failed], to: :pending)
      transition(:succeed, from: :pending, to: :sent)
      transition(:fail, from: [:pending, :failed], to: :failed)
      transition(:mark_unknown, from: :pending, to: :unknown)
      transition(:expire, from: [:pending, :failed], to: :expired)
      transition(:requeue, from: [:failed, :unknown], to: :pending)
    end
  end

  actions do
    defaults([:read])

    create_if_absent :commit do
      transaction?(false)

      accept([
        :agent_uid,
        :binding_name,
        :outbound_key,
        :delivery_class,
        :operation,
        :status,
        :conversation_id,
        :provider_thread_id,
        :reply_to_provider_message_id,
        :target_provider_message_id,
        :target_message_id,
        :reply_to_message_id,
        :expires_at,
        :source_signal_id,
        :ai_message_id,
        :payload,
        :fallback_visible_text,
        :idempotency_key,
        :max_attempts,
        :last_error,
        :recovery_status,
        :recovery_reason,
        :recovery_state
      ])
    end

    in_tx_update :prepare do
      accept([:payload, :operation, :reply_to_provider_message_id, :target_provider_message_id])
      validate(attribute_in(:status, [:pending, :failed]))
    end

    in_tx_update :import_attachments do
      accept([:payload])
      validate(attribute_does_not_equal(:status, :sent))
    end

    in_tx_update :start_attempt do
      accept([:platform_send_started_at])
      require_attributes([:platform_send_started_at])

      change(fn changeset, _context ->
        case check_attempt(changeset.data) do
          :ok ->
            changeset

          {:error, reason} ->
            Ash.Changeset.add_error(
              changeset,
              Ankole.Errors.Invalid.Rejected.exception(reason: reason)
            )
        end
      end)

      change(transition_state(:pending))
      change(atomic_update(:attempt_count, expr(attempt_count + 1)))
      change(set_attribute(:next_attempt_at, nil))
    end

    in_tx_update :succeed do
      accept([
        :created_provider_message_id,
        :provider_thread_id,
        :payload,
        :fallback_visible_text,
        :recovery_state,
        :operation,
        :target_provider_message_id,
        :reply_to_provider_message_id
      ])

      change(transition_state(:sent))
      change(set_attribute(:last_error, %{}))
      change(set_attribute(:next_attempt_at, nil))
      change(set_attribute(:recovery_status, nil))
      change(set_attribute(:recovery_reason, nil))
    end

    in_tx_update :link_message do
      accept([:created_message_id])
      validate(attribute_equals(:status, :sent))
    end

    in_tx_update :fail do
      accept([
        :last_error,
        :next_attempt_at,
        :recovery_status,
        :recovery_reason,
        :possible_duplicate,
        :possible_duplicate_notice
      ])

      change(transition_state(:failed))
    end

    in_tx_update :mark_unknown do
      accept([
        :last_error,
        :recovery_status,
        :recovery_reason,
        :possible_duplicate,
        :possible_duplicate_notice
      ])

      change(transition_state(:unknown))
      change(set_attribute(:next_attempt_at, nil))
    end

    in_tx_update :expire do
      accept([])
      change(transition_state(:expired))
      change(set_attribute(:next_attempt_at, nil))
      change(set_attribute(:recovery_status, nil))
      change(set_attribute(:recovery_reason, nil))
    end

    in_tx_update :requeue do
      accept([
        :payload,
        :fallback_visible_text,
        :possible_duplicate,
        :possible_duplicate_notice,
        :next_attempt_at
      ])

      require_attributes([:next_attempt_at])
      validate(attribute_equals(:delivery_class, :durable_ai_reply))

      validate(fn changeset, _context ->
        if is_nil(changeset.data.next_attempt_at),
          do: :ok,
          else:
            {:error, field: :next_attempt_at, message: "automatic recovery is already scheduled"}
      end)

      change(transition_state(:pending))
      change(atomic_update(:max_attempts, expr(attempt_count + 1)))
      change(set_attribute(:platform_send_started_at, nil))
      change(set_attribute(:recovery_status, nil))
      change(set_attribute(:recovery_reason, nil))
    end
  end

  @doc "Checks the attempt budget and whether another provider send owns the row."
  def check_attempt(%__MODULE__{status: :pending, platform_send_started_at: started_at})
      when not is_nil(started_at),
      do: {:error, :intent_send_in_progress}

  def check_attempt(%__MODULE__{attempt_count: attempts, max_attempts: maximum})
      when attempts >= maximum,
      do: {:error, :intent_attempts_exhausted}

  def check_attempt(%__MODULE__{}), do: :ok
end
