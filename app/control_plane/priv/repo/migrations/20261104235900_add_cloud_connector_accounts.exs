defmodule Ankole.Repo.Migrations.AddCloudConnectorAccounts do
  use Ecto.Migration

  def up do
    alter table(:connector_auth_configs) do
      add :mode, :text, null: false, default: "local"
      modify :sealed_secret, :text, null: true
    end

    create constraint(:connector_auth_configs, :connector_auth_configs_mode_check,
             check:
               "(mode = 'local' AND sealed_secret IS NOT NULL) OR (mode = 'cloud' AND platform_application IS NULL)"
           )

    create unique_index(:connector_auth_configs, [:tenant_id, :plugin_id],
             where: "mode = 'cloud'",
             name: :connector_auth_configs_cloud_per_plugin_uidx
           )

    alter table(:connector_connected_accounts) do
      add :upstream_connection_id, :text
    end

    drop constraint(:connector_connected_accounts, :connector_connected_accounts_check)

    create constraint(:connector_connected_accounts, :connector_connected_accounts_check,
             check:
               "(subject_kind = 'app' AND owner_principal_uid IS NULL) OR (subject_kind = 'human' AND owner_principal_uid IS NOT NULL AND (sealed_credentials IS NOT NULL OR upstream_connection_id IS NOT NULL))"
           )
  end

  def down do
    drop constraint(:connector_connected_accounts, :connector_connected_accounts_check)

    create constraint(:connector_connected_accounts, :connector_connected_accounts_check,
             check:
               "(subject_kind = 'app' AND owner_principal_uid IS NULL) OR (subject_kind = 'human' AND owner_principal_uid IS NOT NULL AND sealed_credentials IS NOT NULL)"
           )

    alter table(:connector_connected_accounts), do: remove(:upstream_connection_id)

    drop index(:connector_auth_configs, [:tenant_id, :plugin_id],
           name: :connector_auth_configs_cloud_per_plugin_uidx
         )

    drop constraint(:connector_auth_configs, :connector_auth_configs_mode_check)

    alter table(:connector_auth_configs) do
      remove :mode
      modify :sealed_secret, :text, null: false
    end
  end
end
