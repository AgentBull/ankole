defmodule Ankole.BrowserSessions.PodAuthentication do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.BrowserSessions.Domain

  postgres do
    table("browser_pod_authentications")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:authentication_id, "browser_pod_authentications_authentication_id_fkey"},
      {:principal_uid, "browser_pod_authentications_principal_uid_fkey"}
    ])
  end

  attributes do
    attribute(:authentication_id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true, allow_nil?: false)
    attribute(:access_version, :integer, public?: true, allow_nil?: false, constraints: [min: 1])
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :record_in_tx do
      accept([:authentication_id, :principal_uid, :access_version])
      transaction?(false)
      upsert?(true)
      upsert_fields([:principal_uid, :access_version, :updated_at])
    end

    destroy :remove_in_tx do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
