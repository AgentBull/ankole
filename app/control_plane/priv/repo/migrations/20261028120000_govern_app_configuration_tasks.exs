defmodule Ankole.Repo.Migrations.GovernAppConfigurationTasks do
  use Ecto.Migration

  def up do
    for table <- ~w(site_app_configurations app_configurations) do
      for {old, new} <- [
            {"agent_computer.worker.ready_timeout", "agent_workers.ready_timeout_seconds"},
            {"worker.rendered_fetch_idle_ttl_ms", "agent_workers.rendered_fetch_idle_ttl_ms"},
            {"agent_computer.background_agent_job.max_running_per_agent",
             "background_agent_jobs.max_running_per_agent"}
          ] do
        execute("UPDATE #{table} SET key = '#{new}' WHERE key = '#{old}'")
      end

      tenant = if table == "app_configurations", do: "tenant_id, ", else: ""

      execute("""
      INSERT INTO #{table} (#{tenant}scope, key, value, inserted_at, updated_at)
      SELECT #{tenant}scope, 'brain.soft_delete_retention_hours',
        jsonb_build_object('type', 'plaintext', 'value', value->'value'->'purge_soft_delete_ttl_hours'),
        inserted_at, updated_at
      FROM #{table}
      WHERE key = 'brain.forgetting' AND value->>'type' = 'plaintext'
        AND value->'value' ? 'purge_soft_delete_ttl_hours'
      """)

      execute("""
      UPDATE #{table} SET value = jsonb_set(value, '{value}', (value->'value') - 'purge_soft_delete_ttl_hours')
      WHERE key = 'brain.forgetting' AND value->>'type' = 'plaintext'
      """)
    end

    for {kind, fields} <- [
          {"send",
           [
             {"window_seconds", "window_seconds", 60},
             {"email_limit", "per_email", 3},
             {"source_limit", "per_source", 20},
             {"channel_limit", "per_channel", 100}
           ]},
          {"failure",
           [
             {"window_seconds", "window_seconds", 600},
             {"email_limit", "per_email", 10},
             {"source_limit", "per_source", 100}
           ]}
        ] do
      fields_sql =
        Enum.map_join(fields, ", ", fn {old, new, default} ->
          "'#{new}', COALESCE((SELECT value->'value' FROM site_app_configurations WHERE scope = 'global' AND key = 'authn.email.#{kind}_#{old}'), '#{default}'::jsonb)"
        end)

      execute("""
      INSERT INTO site_app_configurations (scope, key, value, inserted_at, updated_at)
      SELECT 'global', 'authn.email.#{kind}_limits',
        jsonb_build_object('type', 'plaintext', 'value', jsonb_build_object(#{fields_sql})), now(), now()
      WHERE EXISTS (SELECT 1 FROM site_app_configurations WHERE key LIKE 'authn.email.#{kind}_%' AND scope = 'global')
      """)

      for {old, _, _} <- fields,
          do:
            execute(
              "DELETE FROM site_app_configurations WHERE scope = 'global' AND key = 'authn.email.#{kind}_#{old}'"
            )
    end

    execute("""
    INSERT INTO site_app_configurations (scope, key, value, inserted_at, updated_at)
    SELECT 'global', 'saas.turnstile.enabled', jsonb_build_object('type', 'plaintext', 'value',
      EXISTS (SELECT 1 FROM site_app_configurations WHERE key = 'saas.turnstile.site_key' AND scope = 'global' AND coalesce(value->>'value', '') != '')
      AND EXISTS (SELECT 1 FROM site_app_configurations WHERE key = 'saas.turnstile.secret_key' AND scope = 'global')),
      now(), now()
    WHERE EXISTS (SELECT 1 FROM site_app_configurations WHERE key LIKE 'saas.turnstile.%')
    """)
  end

  def down,
    do:
      raise(
        "Configuration key consolidation requires restoring the corresponding application snapshot"
      )
end
