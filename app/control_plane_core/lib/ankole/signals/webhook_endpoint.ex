defmodule Ankole.Signals.WebhookEndpoint do
  @moduledoc """
  One capability URL for raw task receipts or structured CloudEvents.

  The row stores only the token digest. The plaintext capability URL exists
  only in the create response and in the external system that receives it.
  """

  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Signals,
    extensions: [Ankole.AuthZ.Extension, AshStateMachine, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_list, resource: "site_console:webhooks", action: "read")
    allow(:create_operator_endpoint, resource: "site_console:webhooks", action: "update")
    allow(:cancel_operator_endpoint, resource: "site_console:webhooks", action: "delete")
  end

  @modes ~w(one_shot standing)
  @type t :: %__MODULE__{}

  postgres do
    table("signal_webhook_endpoints")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "signal_webhook_endpoints_agent_uid_fkey"},
      {:source_signal_id, "signal_webhook_endpoints_source_signal_id_fkey"},
      {:conversation_id, "signal_webhook_endpoints_conversation_id_fkey"},
      {:automation_job_id, "signal_webhook_endpoints_automation_job_id_fkey"}
    ])

    unique_index_names([{[:token_digest], "signal_webhook_endpoints_token_digest_index"}])

    check_constraints do
      check_constraint(:mode, "signal_webhook_endpoints_mode_check")
      check_constraint(:event_format, "signal_webhook_endpoints_event_format_check")
      check_constraint(:agent_uid, "signal_webhook_endpoints_raw_target_check")
      check_constraint(:status, "signal_webhook_endpoints_status_check")
      check_constraint(:status, "signal_webhook_endpoints_lifecycle_check")
      check_constraint(:token_digest, "signal_webhook_endpoints_token_digest_length")
      check_constraint(:label, "signal_webhook_endpoints_label_present")
      check_constraint(:binding_name, "signal_webhook_endpoints_binding_name_present")
      check_constraint(:session_id, "signal_webhook_endpoints_session_id_present")
      check_constraint(:source_provenance, "signal_webhook_endpoints_source_provenance_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0,
      public?: true
    )

    attribute(:token_digest, :string,
      allow_nil?: false,
      constraints: [min_length: 43, max_length: 43],
      public?: true
    )

    attribute(:event_format, :string, allow_nil?: false, default: "raw", public?: true)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, public?: true)
    attribute(:binding_name, :string, public?: true)
    attribute(:session_id, :string, public?: true)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:provider_thread_id, :string, public?: true)
    attribute(:source_signal_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:provider_message_id, :string, public?: true)

    attribute(:source_provenance, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    attribute(:label, :string, allow_nil?: false, constraints: [max_length: 500], public?: true)
    attribute(:mode, :string, allow_nil?: false, public?: true)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:fired_at, :utc_datetime_usec, public?: true)
    attribute(:cancelled_at, :utc_datetime_usec, public?: true)
    attribute(:automation_job_id, :integer, public?: true)
    timestamps(type: :utc_datetime_usec, public?: true)
  end

  # The token digest stays private: it identifies the capability URL.
  json_api do
    type("webhook_endpoint")
    derive_filter?(false)
    derive_sort?(false)
    hide_fields([:token_digest])

    default_fields([
      :id,
      :agent_uid,
      :binding_name,
      :session_id,
      :conversation_id,
      :provider_thread_id,
      :source_signal_id,
      :event_format,
      :provider_message_id,
      :source_provenance,
      :automation_job_id,
      :label,
      :mode,
      :status,
      :expires_at,
      :fired_at,
      :cancelled_at,
      :inserted_at,
      :updated_at
    ])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:armed, :active])
    default_initial_state(:armed)

    transitions do
      transition(:fire, from: :armed, to: :fired)
      transition(:cancel, from: [:armed, :active], to: :cancelled)
      transition(:expire, from: [:armed, :active], to: :expired)
    end
  end

  actions do
    defaults([:read])

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    # The Console list: the newest endpoints first, of one Agent or of all Agents.
    read :console_list do
      argument(:agent, Ankole.Ash.Types.PrincipalKey)
      filter(expr(is_nil(^arg(:agent)) or agent_uid == ^arg(:agent)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
      pagination(keyset?: true, default_limit: 100, max_page_size: 500, countable: false)
    end

    create :create do
      primary?(true)

      accept([
        :token_digest,
        :event_format,
        :agent_uid,
        :binding_name,
        :session_id,
        :conversation_id,
        :provider_thread_id,
        :source_signal_id,
        :provider_message_id,
        :source_provenance,
        :label,
        :mode,
        :expires_at,
        :automation_job_id
      ])

      change(transition_state(:active), where: [attribute_equals(:mode, "standing")])
      validate(one_of(:mode, @modes))
      validate(one_of(:event_format, ["raw", "cloudevents"]))

      validate(present([:agent_uid, :session_id]),
        where: [attribute_equals(:event_format, "raw")]
      )

      validate(
        fn changeset, _context ->
          label = Ash.Changeset.get_attribute(changeset, :label)

          if String.valid?(label) and not String.contains?(label, <<0>>),
            do: :ok,
            else: {:error, field: :label, message: "must be valid text without NUL"}
        end,
        only_when_valid?: true
      )
    end

    update :fire do
      accept([:fired_at])
      change(transition_state(:fired))
      validate(present(:fired_at))
    end

    update :cancel do
      accept([:cancelled_at])
      change(transition_state(:cancelled))
      validate(present(:cancelled_at))
    end

    update :expire do
      require_atomic?(true)
      accept([])
      change(transition_state(:expired))
    end

    # The Console creates a standing CloudEvents endpoint. The plaintext token
    # is in this result only.
    action :create_operator_endpoint, :map do
      constraints(
        fields: [
          webhook_endpoint: [
            type: :struct,
            allow_nil?: false,
            constraints: [instance_of: __MODULE__]
          ],
          token: [type: :string, allow_nil?: false]
        ]
      )

      argument(:label, :string, allow_nil?: false)
      argument(:expires_at, :utc_datetime_usec, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    action :cancel_operator_endpoint, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end
  end
end
