defmodule Ankole.BrowserSessions.Session do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :site, domain: Ankole.BrowserSessions

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
    validate(compare(:logout_revision, less_than_or_equal_to: :revision),
      message: "cannot exceed the browser revision",
      only_when_valid?: true
    )
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([:expires_at])
    end

    update :activate_in_tx do
      accept([:active_authentication_id, :active_tenant_id])
    end

    update :record_login_in_tx do
      accept([:revision, :active_authentication_id, :active_tenant_id, :expires_at])
    end

    update :revoke_in_tx do
      accept([:revision, :active_authentication_id, :active_tenant_id])
    end

    update :logout_in_tx do
      accept([:revision, :logout_revision])
      change(set_attribute(:active_authentication_id, nil))
      change(set_attribute(:active_tenant_id, nil))
    end

    destroy :expire_in_tx do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
