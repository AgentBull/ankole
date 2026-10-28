defmodule Ankole.Repo.Migrations.ScopeDefaultLocaleToPod do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO app_configurations (tenant_id, scope, key, value, inserted_at, updated_at)
    SELECT
      t.id,
      'tenant:' || t.id::text,
      'i18n.default_locale',
      s.value,
      s.inserted_at,
      s.updated_at
    FROM tenants t
    CROSS JOIN site_app_configurations s
    WHERE s.scope = 'global'
      AND s.key = 'i18n.default_locale'
      AND s.value->>'type' = 'plaintext'
      AND jsonb_typeof(s.value->'value') = 'string'
    ON CONFLICT (tenant_id, scope, key) DO NOTHING
    """)

    execute("""
    DELETE FROM app_configurations
    WHERE key = 'i18n.default_locale'
      AND scope LIKE 'agent:%'
    """)

    execute("""
    DELETE FROM site_app_configurations
    WHERE scope = 'global'
      AND key = 'i18n.default_locale'
    """)
  end

  def down do
    :ok
  end
end
