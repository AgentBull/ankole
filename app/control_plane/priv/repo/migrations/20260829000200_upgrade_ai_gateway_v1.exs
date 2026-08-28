defmodule Ankole.Repo.Migrations.UpgradeAIGatewayV1 do
  use Ecto.Migration

  def up do
    normalize_provider_credentials()

    alter table(:ai_gateway_artifacts) do
      add :provider_item_id, :text
    end

    create index(:ai_gateway_artifacts, [:subject_uid, :provider_item_id],
             name: :ai_gateway_artifacts_provider_item_index,
             where: "provider_item_id IS NOT NULL"
           )

    drop constraint(:ai_gateway_messages, :ai_gateway_messages_role_check)

    alter table(:ai_gateway_messages) do
      remove :role
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "the pre-v1 AIGateway state cannot be restored after the v1 upgrade"
  end

  defp normalize_provider_credentials do
    execute("""
    UPDATE ai_gateway_providers AS provider
    SET credential_pool = jsonb_set(
          credential_pool,
          '{entries}',
          (
            SELECT jsonb_agg(
                     CASE
                       WHEN NULLIF(btrim(entry->>'health_revision'), '') IS NULL
                         THEN entry || '{"health_revision":"v1-upgrade"}'::jsonb
                       ELSE entry
                     END
                     ORDER BY ordinal
                   )
            FROM jsonb_array_elements(provider.credential_pool->'entries')
                 WITH ORDINALITY AS item(entry, ordinal)
          ),
          false
        )
    WHERE EXISTS (
      SELECT 1
      FROM jsonb_array_elements(provider.credential_pool->'entries') AS item(entry)
      WHERE NULLIF(btrim(entry->>'health_revision'), '') IS NULL
    )
    """)
  end
end
