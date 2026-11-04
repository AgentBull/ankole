defmodule Ankole.Connectors.ConnectedAccount do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Connectors

  postgres do
    table("connector_connected_accounts")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:tenant_id, :auth_config_id, :subject_kind, :account_key],
       "connector_connected_accounts_tenant_id_auth_config_id_subje_key"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:auth_config_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:plugin_id, :string, allow_nil?: false)
    attribute(:subject_kind, :string, allow_nil?: false)
    attribute(:account_key, :string, allow_nil?: false)
    attribute(:owner_principal_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:owner_access_version, :integer)
    attribute(:external_subject_id, :string)
    attribute(:granted_scopes, {:array, :string}, allow_nil?: false, default: [])
    attribute(:public_metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:sealed_credentials, :string, sensitive?: true)
    attribute(:upstream_connection_id, :string)
    attribute(:credentials_version, :integer, allow_nil?: false, default: 1)
    attribute(:status, :string, allow_nil?: false, default: "active")
    attribute(:expires_at, :utc_datetime_usec)
    attribute(:refresh_expires_at, :utc_datetime_usec)
    attribute(:refreshing_until, :utc_datetime_usec)
    attribute(:last_refreshed_at, :utc_datetime_usec)
    attribute(:last_refresh_failure_at, :utc_datetime_usec)
    attribute(:first_refresh_failure_at, :utc_datetime_usec)
    attribute(:refresh_lease_id, :string)
    attribute(:last_error, Ankole.Ash.Types.JSONMap)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    read :across_tenants do
      multitenancy(:allow_global)
    end

    create :create do
      accept([
        :id
        | [
            :auth_config_id,
            :plugin_id,
            :subject_kind,
            :account_key,
            :owner_principal_uid,
            :owner_access_version,
            :external_subject_id,
            :granted_scopes,
            :public_metadata,
            :sealed_credentials,
            :upstream_connection_id,
            :credentials_version,
            :status,
            :expires_at,
            :refresh_expires_at,
            :refreshing_until,
            :last_refreshed_at,
            :last_refresh_failure_at,
            :first_refresh_failure_at,
            :refresh_lease_id,
            :last_error
          ]
      ])
    end

    update :update do
      accept([
        :auth_config_id,
        :plugin_id,
        :subject_kind,
        :account_key,
        :owner_principal_uid,
        :owner_access_version,
        :external_subject_id,
        :granted_scopes,
        :public_metadata,
        :sealed_credentials,
        :upstream_connection_id,
        :credentials_version,
        :status,
        :expires_at,
        :refresh_expires_at,
        :refreshing_until,
        :last_refreshed_at,
        :last_refresh_failure_at,
        :first_refresh_failure_at,
        :refresh_lease_id,
        :last_error
      ])

      require_atomic?(false)
    end

    destroy :destroy do
    end
  end
end
