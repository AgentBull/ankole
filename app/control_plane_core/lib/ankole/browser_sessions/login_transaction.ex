defmodule Ankole.BrowserSessions.LoginTransaction do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: Ankole.BrowserSessions.Domain,
    extensions: [AshStateMachine]

  postgres do
    table("browser_login_transactions")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:tenant_id, "browser_login_transactions_tenant_id_fkey"},
      {:browser_id, "browser_login_transactions_browser_id_fkey"},
      {:expected_authentication_id, "browser_login_transactions_expected_authentication_id_fkey"},
      {:authentication_id, "browser_login_transactions_authentication_id_fkey"}
    ])

    unique_index_names([{[:upstream_state], "browser_login_transactions_upstream_state_index"}])

    check_constraints do
      check_constraint(:purpose, "browser_login_transactions_purpose")
      check_constraint(:mode, "browser_login_transactions_mode")
      check_constraint(:tenant_id, "browser_login_transactions_target")
      check_constraint(:status, "browser_login_transactions_status")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:tenant_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:browser_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)

    attribute(:started_revision, :integer,
      public?: true,
      allow_nil?: false,
      constraints: [min: 0]
    )

    attribute(:purpose, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:console, :oauth, :pod, :site]]
    )

    attribute(:mode, :atom,
      public?: true,
      allow_nil?: false,
      default: :replace,
      constraints: [one_of: [:replace, :add]]
    )

    attribute(:expected_authentication_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:authentication_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:authentication_revision, :integer, public?: true, constraints: [min: 1])

    attribute(:csrf_token, :string,
      public?: true,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false]
    )

    attribute(:request, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    attribute(:provider_id, :string, public?: true, constraints: [trim?: false])

    attribute(:upstream_state, :string,
      public?: true,
      sensitive?: true,
      constraints: [trim?: false]
    )

    attribute(:redirect_uri, :string, public?: true, constraints: [trim?: false])
    attribute(:password_ticket, Ankole.Ash.Types.JSONMap, public?: true, sensitive?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    timestamps(type: :utc_datetime_usec)
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:authenticate_in_tx, from: [:pending, :authenticated], to: :authenticated)
      transition(:consume_in_tx, from: [:pending, :authenticated], to: :consumed)
      transition(:reauthenticate_in_tx, from: [:pending, :authenticated], to: :pending)
      transition(:cancel_in_tx, from: [:pending, :authenticated], to: :cancelled)
    end
  end

  actions do
    defaults([:read])

    create :begin_in_tx do
      accept([
        :browser_id,
        :tenant_id,
        :started_revision,
        :purpose,
        :mode,
        :expected_authentication_id,
        :request,
        :csrf_token,
        :expires_at
      ])

      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      validate(Ankole.BrowserSessions.Validations.TargetScope, only_when_valid?: true)
    end

    in_tx_update :bind_provider_in_tx do
      accept([:provider_id, :upstream_state, :redirect_uri])
      validate(attribute_equals(:status, :pending))
    end

    in_tx_update :password_ticket_in_tx do
      accept([:password_ticket])
      validate(attribute_equals(:status, :pending))
    end

    in_tx_update :bind_proof_in_tx do
      accept([:authentication_id, :authentication_revision, :upstream_state])
      validate(attribute_equals(:status, :pending))
      validate(present([:authentication_id, :authentication_revision]))
    end

    in_tx_update :authenticate_in_tx do
      accept([:authentication_id, :authentication_revision, :request, :started_revision])
      validate(present([:authentication_id, :authentication_revision]))
      change(transition_state(:authenticated))
      change(set_attribute(:password_ticket, nil))
    end

    in_tx_update :consume_in_tx do
      accept([:authentication_id, :authentication_revision, :request, :started_revision])
      change(transition_state(:consumed))
      change(set_attribute(:password_ticket, nil))
    end

    in_tx_update :reauthenticate_in_tx do
      accept([:expected_authentication_id, :request, :started_revision])
      change(transition_state(:pending))
      change(set_attribute(:authentication_id, nil))
      change(set_attribute(:authentication_revision, nil))
    end

    atomic_in_tx_update :cancel_in_tx do
      accept([])
      change(transition_state(:cancelled))
      change(set_attribute(:password_ticket, nil))
    end

    destroy :expire_in_tx do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
