defmodule Ankole.Connectors.AuthConfig do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Connectors

  postgres do
    table("connector_auth_configs")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:tenant_id, :slug], "connector_auth_configs_tenant_id_slug_key"},
      {[:plugin_id], "connector_auth_configs_default_per_plugin_uidx"},
      {[:platform_application], "connector_auth_configs_active_platform_app_uidx"},
      {[:plugin_id, :platform_client_id], "connector_auth_configs_active_platform_client_uidx"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:plugin_id, :string, allow_nil?: false)
    attribute(:slug, :string, allow_nil?: false)
    attribute(:display_name, :string, allow_nil?: false)
    attribute(:auth_scheme, :string, allow_nil?: false)
    attribute(:is_default, :boolean, allow_nil?: false, default: false)
    attribute(:platform_application, :string)
    attribute(:platform_client_id, :string)
    attribute(:public_metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:sealed_secret, :string, allow_nil?: false, sensitive?: true)
    attribute(:secret_version, :integer, allow_nil?: false, default: 1)
    attribute(:status, :string, allow_nil?: false, default: "active")
    attribute(:created_by_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
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
            :plugin_id,
            :slug,
            :display_name,
            :auth_scheme,
            :is_default,
            :platform_application,
            :platform_client_id,
            :public_metadata,
            :sealed_secret,
            :secret_version,
            :status,
            :created_by_uid
          ]
      ])
    end

    update :update do
      accept([
        :plugin_id,
        :slug,
        :display_name,
        :auth_scheme,
        :is_default,
        :platform_application,
        :platform_client_id,
        :public_metadata,
        :sealed_secret,
        :secret_version,
        :status,
        :created_by_uid
      ])

      require_atomic?(false)
    end

    destroy :destroy do
    end
  end
end
