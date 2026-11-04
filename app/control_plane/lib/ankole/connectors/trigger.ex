defmodule Ankole.Connectors.Trigger do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Connectors

  postgres do
    table("connector_triggers")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:tenant_id, :auth_config_id, :trigger_type, :scope_key],
       "connector_triggers_tenant_id_auth_config_id_trigger_type_sc_key"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:auth_config_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:connected_account_id, Ankole.Ash.Types.UUIDv7)
    attribute(:plugin_id, :string, allow_nil?: false)
    attribute(:trigger_type, :string, allow_nil?: false)
    attribute(:scope_key, :string, allow_nil?: false)
    attribute(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:external_subscription_id, :string)
    attribute(:sealed_secret, :string, sensitive?: true)
    attribute(:status, :string, allow_nil?: false, default: "provisioning")
    attribute(:lease_expires_at, :utc_datetime_usec)
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
            :connected_account_id,
            :plugin_id,
            :trigger_type,
            :scope_key,
            :config,
            :external_subscription_id,
            :sealed_secret,
            :status,
            :lease_expires_at,
            :last_error
          ]
      ])
    end

    update :update do
      accept([
        :auth_config_id,
        :connected_account_id,
        :plugin_id,
        :trigger_type,
        :scope_key,
        :config,
        :external_subscription_id,
        :sealed_secret,
        :status,
        :lease_expires_at,
        :last_error
      ])

      require_atomic?(false)
    end

    destroy :destroy do
    end
  end
end
