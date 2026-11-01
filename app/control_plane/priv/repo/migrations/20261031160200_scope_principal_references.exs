defmodule Ankole.Repo.Migrations.ScopePrincipalReferences do
  use Ecto.Migration

  def up do
    for name <- ~w(
      agent_library_container_entries_active_path_index
      agent_plugin_overrides_agent_plugin_index
      agent_skills_agent_skill_index
      ai_gateway_conversations_active_key_index
      background_agent_jobs_source_tool_call_index
      cron_schedules_agent_name_index
      cron_schedules_idempotency_index
      human_access_events_source_operation_id_principal_uid_index
      permission_grants_principal_natural_index
      scheduled_events_idempotency_index
      sessions_session_index
      workflow_runs_source_tool_call_index
    ) do
      execute("""
      DO $$ DECLARE definition text;
      BEGIN
        SELECT pg_get_indexdef('#{name}'::regclass) INTO definition;
        DROP INDEX #{name};
        EXECUTE replace(definition, 'USING btree (', 'USING btree (tenant_id, ');
      END $$;
      """)
    end

    for {table, columns} <- [
          {"deliveries", "agent_uid, binding_name, outbound_key"},
          {"signal_bindings", "agent_uid, name"}
        ] do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_pkey")
      execute("ALTER TABLE #{table} ADD PRIMARY KEY (tenant_id, #{columns})")
    end
  end

  def down do
    raise "Tenant-local references require tenant-local uniqueness"
  end
end
