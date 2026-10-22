defmodule Ankole.BrowserSessions.Session do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :site, domain: Ankole.BrowserSessions.Domain

  postgres do
    table("browser_sessions")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:active_tenant_id, "browser_sessions_active_tenant_id_fkey"}])

    check_constraints do
      check_constraint(:revision, "browser_sessions_revisions")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:revision, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:logout_revision, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:active_authentication_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:active_tenant_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    timestamps(type: :utc_datetime_usec)
  end

  validations do
    validate(
      fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :logout_revision) <=
             Ash.Changeset.get_attribute(changeset, :revision),
           do: :ok,
           else: {:error, field: :logout_revision, message: "cannot exceed the browser revision"}
      end,
      only_when_valid?: true
    )
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([:expires_at])
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
    end

    in_tx_update :activate_in_tx do
      accept([:active_authentication_id, :active_tenant_id])
    end

    in_tx_update :record_login_in_tx do
      accept([:revision, :active_authentication_id, :active_tenant_id, :expires_at])
    end

    in_tx_update :revoke_in_tx do
      accept([:revision, :active_authentication_id, :active_tenant_id])
    end

    in_tx_update :logout_in_tx do
      accept([:revision, :logout_revision])
      change(set_attribute(:active_authentication_id, nil))
      change(set_attribute(:active_tenant_id, nil))
    end

    destroy :expire_in_tx do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
