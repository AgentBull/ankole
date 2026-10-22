defmodule Ankole.OIDC.LogoutRequest do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.OIDC.Domain

  postgres do
    table("oidc_logout_requests")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names(
      browser_id: "oidc_logout_requests_browser_id_fkey",
      client_id: "oidc_logout_requests_client_id_fkey"
    )

    check_constraints do
      check_constraint(:browser_revision, "oidc_logout_requests_browser_revision_nonnegative")
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

    attribute(:browser_revision, :integer,
      public?: true,
      allow_nil?: false,
      constraints: [min: 0]
    )

    attribute(:client_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:redirect_uri, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:state, :string, public?: true, constraints: [trim?: false, allow_empty?: true])
    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:confirmed_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    create :prepare_in_tx do
      accept([:browser_id, :browser_revision, :client_id, :redirect_uri, :state, :expires_at])
      transaction?(false)
    end

    atomic_in_tx_update :confirm_in_tx do
      accept([])
      change(filter(expr(is_nil(confirmed_at))))
      change(set_attribute(:confirmed_at, &DateTime.utc_now/0))
    end

    destroy :cancel_in_tx do
      transaction?(false)
      require_atomic?(true)
      change(filter(expr(is_nil(confirmed_at))))
    end

    destroy :expire_in_tx do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
