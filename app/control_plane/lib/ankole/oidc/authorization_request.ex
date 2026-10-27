defmodule Ankole.OIDC.AuthorizationRequest do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.OIDC,
    extensions: [AshStateMachine]

  postgres do
    table("oidc_authorization_requests")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names(
      tenant_id: "oidc_authorization_requests_tenant_id_fkey",
      browser_id: "oidc_authorization_requests_browser_id_fkey",
      client_id: "oidc_authorization_requests_client_id_fkey",
      expected_authentication_id: "oidc_authorization_requests_expected_authentication_id_fkey",
      authentication_id: "oidc_authorization_requests_authentication_id_fkey"
    )

    check_constraints do
      check_constraint(
        :started_revision,
        "oidc_authorization_requests_started_revision_nonnegative"
      )

      check_constraint(:status, "oidc_authorization_requests_status")
      check_constraint(:authentication_id, "oidc_authorization_requests_authentication")
      check_constraint(:request, "oidc_authorization_requests_request_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:browser_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:client_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)

    attribute(:started_revision, :integer,
      public?: true,
      allow_nil?: false,
      constraints: [min: 0]
    )

    attribute(:request, Ankole.Ash.Types.JSONMap,
      public?: true,
      allow_nil?: false,
      default: %{}
    )

    attribute(:expected_authentication_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:authentication_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:authentication_revision, :integer, public?: true, constraints: [min: 1])
    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    timestamps(type: :utc_datetime_usec)
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:authenticate_in_tx, from: [:pending, :authenticated], to: :authenticated)
      transition(:reauthenticate_in_tx, from: [:pending, :authenticated], to: :pending)
      transition(:consume_in_tx, from: [:authenticated], to: :consumed)
      transition(:cancel_in_tx, from: [:pending, :authenticated], to: :cancelled)
    end
  end

  actions do
    defaults([:read])

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    create :begin_in_tx do
      accept([
        :browser_id,
        :client_id,
        :started_revision,
        :request,
        :expected_authentication_id,
        :expires_at
      ])
    end

    update :authenticate_in_tx do
      accept([:authentication_id, :authentication_revision, :request, :started_revision])
      validate(present([:authentication_id, :authentication_revision]))
      change(transition_state(:authenticated))
    end

    update :reauthenticate_in_tx do
      accept([:expected_authentication_id, :request, :started_revision])
      change(transition_state(:pending))
      change(set_attribute(:authentication_id, nil))
      change(set_attribute(:authentication_revision, nil))
    end

    update :consume_in_tx do
      accept([])
      change(transition_state(:consumed))
    end

    update :cancel_in_tx do
      require_atomic?(true)
      accept([])
      change(transition_state(:cancelled))
    end

    destroy :expire_in_tx do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
