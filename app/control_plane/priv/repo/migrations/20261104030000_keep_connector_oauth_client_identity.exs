defmodule Ankole.Repo.Migrations.KeepConnectorOAuthClientIdentity do
  use Ecto.Migration

  def up do
    alter table(:connector_auth_configs) do
      add(:platform_client_id, :text)
    end

    flush()

    %{rows: rows} =
      repo().query!(
        "SELECT id::text, tenant_id::text, sealed_secret FROM connector_auth_configs WHERE plugin_id = 'slack'"
      )

    Enum.each(rows, fn [id, tenant_id, sealed] ->
      with {:ok, json} <-
             Ankole.SecretKeyBase.unseal(sealed, "connector_auth_config", [tenant_id, id]),
           {:ok, secret} <- Ankole.JSON.decode(json) do
        repo().query!(
          "UPDATE connector_auth_configs SET platform_client_id = $1 WHERE id = $2::text::uuid",
          [if(secret["clientID"] == "", do: nil, else: secret["clientID"]), id]
        )
      else
        _ -> raise Ecto.MigrationError, message: "Cannot read Slack connection #{id}"
      end
    end)

    create(
      unique_index(:connector_auth_configs, [:plugin_id, :platform_client_id],
        name: :connector_auth_configs_active_platform_client_uidx,
        where: "status = 'active' AND platform_client_id IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      index(:connector_auth_configs, [:plugin_id, :platform_client_id],
        name: :connector_auth_configs_active_platform_client_uidx
      )
    )

    alter table(:connector_auth_configs) do
      remove(:platform_client_id)
    end
  end
end
