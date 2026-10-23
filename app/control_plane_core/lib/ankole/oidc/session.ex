defmodule Ankole.OIDC.Session do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.OIDC

  postgres do
    table("oidc_sessions")
    repo(Ankole.Repo)
    migrate?(false)

    identity_index_names(
      authentication: "oidc_sessions_client_id_authentication_id_authentication_revisi"
    )

    foreign_key_names(
      client_id: "oidc_sessions_client_id_fkey",
      principal_uid: "oidc_sessions_principal_uid_fkey",
      browser_id: "oidc_sessions_browser_id_fkey",
      authentication_id: "oidc_sessions_authentication_id_fkey"
    )

    check_constraints do
      check_constraint(:access_version, "oidc_sessions_access_version_positive")
      check_constraint(:authentication_revision, "oidc_sessions_authentication_revision_positive")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:client_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true, allow_nil?: false)
    attribute(:browser_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:authentication_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:authentication_revision, :integer, public?: true, constraints: [min: 1])
    attribute(:access_version, :integer, public?: true, allow_nil?: false, constraints: [min: 1])

    attribute(:provider_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:auth_time, :integer, public?: true)
    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:ended_at, :utc_datetime_usec, public?: true)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:authentication, [:client_id, :authentication_id, :authentication_revision],
      all_tenants?: true
    )
  end

  actions do
    defaults([:read])

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    # One statement inserts the Session or extends its deadline. The upsert
    # locks a conflicting row like the insert of a new row, and changes only a
    # later deadline, so a repeated authorization never shortens a Session that
    # live refresh tokens use.
    create :authorize_in_tx do
      accept([
        :client_id,
        :principal_uid,
        :browser_id,
        :authentication_id,
        :authentication_revision,
        :access_version,
        :provider_id,
        :auth_time,
        :expires_at
      ])

      upsert?(true)
      upsert_identity(:authentication)
      upsert_fields([:expires_at])
      upsert_condition(expr(expires_at < upsert_conflict(:expires_at)))
      return_skipped_upsert?(true)
      validate(present([:authentication_id, :authentication_revision]))
    end

    update :revoke_in_tx do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
      change(atomic_update(:revoked_at, expr(fragment("COALESCE(?, ?)", revoked_at, ^arg(:at)))))
    end

    update :end_in_tx do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
      change(atomic_update(:ended_at, expr(fragment("COALESCE(?, ?)", ended_at, ^arg(:at)))))
    end

    update :revoke_and_end_in_tx do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
      change(atomic_update(:revoked_at, expr(fragment("COALESCE(?, ?)", revoked_at, ^arg(:at)))))
      change(atomic_update(:ended_at, expr(fragment("COALESCE(?, ?)", ended_at, ^arg(:at)))))
    end

    destroy :expire_in_tx do
      require_atomic?(true)
    end

    action :ensure, :struct do
      constraints(instance_of: __MODULE__)
      argument(:client_id, :term)
      argument(:auth, :term)
      argument(:scope, :term)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
