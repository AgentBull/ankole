defmodule Ankole.Repo.Migrations.RenameSubagentDelegationsToBackgroundAgentJobs do
  use Ecto.Migration

  @old_config_key "agent_computer.subagent.max_delegation_turns_per_worker"
  @new_config_key "agent_computer.background_agent_job.max_turns_per_worker"

  @job_columns [
    {"session_id", "owner_session_id"},
    {"actor_event_id", "source_actor_event_id"},
    {"tool_call_id", "source_tool_call_id"},
    {"source_delegation_id", "source_job_id"}
  ]
  @turn_columns [{"delegation_id", "job_id"}]

  @job_constraints [
    {"subagent_delegations_pkey", "background_agent_jobs_pkey"},
    {"subagent_delegations_agent_uid_fkey", "background_agent_jobs_agent_uid_fkey"},
    {"subagent_delegations_actor_event_id_fkey",
     "background_agent_jobs_source_actor_event_id_fkey"},
    {"subagent_delegations_source_delegation_id_fkey",
     "background_agent_jobs_source_job_id_fkey"},
    {"subagent_delegations_id_range", "background_agent_jobs_id_range"},
    {"subagent_delegations_status_check", "background_agent_jobs_status_check"},
    {"subagent_delegations_result_object", "background_agent_jobs_result_object"},
    {"subagent_delegations_error_object", "background_agent_jobs_error_object"},
    {"subagent_delegations_metadata_object", "background_agent_jobs_metadata_object"},
    {"subagent_delegations_runtime_check", "background_agent_jobs_runtime_check"},
    {"subagent_delegations_reply_route_object", "background_agent_jobs_reply_route_object"},
    {"subagent_delegations_attempts_nonnegative", "background_agent_jobs_attempts_nonnegative"},
    {"subagent_delegations_research_contract_check",
     "background_agent_jobs_research_contract_check"},
    {"subagent_delegations_workspace_retention_check",
     "background_agent_jobs_workspace_retention_check"}
  ]

  @job_indexes [
    {"subagent_delegations_agent_session_index",
     "background_agent_jobs_agent_owner_session_index"},
    {"subagent_delegations_agent_status_index", "background_agent_jobs_agent_status_index"},
    {"subagent_delegations_agent_status_queued_index",
     "background_agent_jobs_agent_status_queued_index"},
    {"subagent_delegations_agent_channel_queued_index",
     "background_agent_jobs_agent_channel_queued_index"},
    {"subagent_delegations_parent_tool_call_index",
     "background_agent_jobs_source_tool_call_index"},
    {"subagent_delegations_running_worker_route_index",
     "background_agent_jobs_running_worker_route_index"},
    {"subagent_delegations_codex_account_status_index",
     "background_agent_jobs_codex_account_status_index"},
    {"subagent_delegations_source_index", "background_agent_jobs_source_job_index"},
    {"subagent_delegations_research_workspace_cleanup_index",
     "background_agent_jobs_research_workspace_cleanup_index"}
  ]

  @turn_constraints [
    {"subagent_delegation_turns_pkey", "background_agent_job_turns_pkey"},
    {"subagent_delegation_turns_delegation_id_fkey", "background_agent_job_turns_job_id_fkey"},
    {"subagent_delegation_turns_attempt_positive", "background_agent_job_turns_attempt_positive"},
    {"subagent_delegation_turns_revision_nonnegative",
     "background_agent_job_turns_revision_nonnegative"},
    {"subagent_delegation_turns_kind_check", "background_agent_job_turns_kind_check"},
    {"subagent_delegation_turns_status_check", "background_agent_job_turns_status_check"},
    {"subagent_delegation_turns_trajectory_check", "background_agent_job_turns_trajectory_check"},
    {"subagent_delegation_turns_trajectory_bytes", "background_agent_job_turns_trajectory_bytes"},
    {"subagent_delegation_turns_usage_object", "background_agent_job_turns_usage_object"},
    {"subagent_delegation_turns_error_object", "background_agent_job_turns_error_object"},
    {"subagent_delegation_turns_completion_check", "background_agent_job_turns_completion_check"},
    {"subagent_delegation_turns_progress_object", "background_agent_job_turns_progress_object"}
  ]

  @turn_indexes [
    {"subagent_delegation_turns_runtime_turn_index",
     "background_agent_job_turns_runtime_turn_index"},
    {"subagent_delegation_turns_timeline_index", "background_agent_job_turns_timeline_index"}
  ]

  def up do
    execute("ALTER TABLE subagent_delegations RENAME TO background_agent_jobs")
    execute("ALTER TABLE subagent_delegation_turns RENAME TO background_agent_job_turns")

    rename_columns("background_agent_jobs", @job_columns)
    rename_columns("background_agent_job_turns", @turn_columns)
    rename_constraints("background_agent_jobs", @job_constraints)
    rename_indexes(@job_indexes)
    rename_constraints("background_agent_job_turns", @turn_constraints)
    rename_indexes(@turn_indexes)
    execute(config_key_migration_sql())
  end

  def down do
    raise "BackgroundAgentJob naming migration cannot be downgraded after the v0.7.0 runtime cutover"
  end

  @doc false
  def config_key_migration_sql(table \\ "app_configurations") do
    table = validate_table!(table)

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{table} old_config
        JOIN #{table} new_config ON new_config.scope = old_config.scope
        WHERE old_config.key = '#{@old_config_key}'
          AND new_config.key = '#{@new_config_key}'
      ) THEN
        RAISE EXCEPTION
          'Both old and new BackgroundAgentJob AppConfigure keys exist for one scope';
      END IF;

      UPDATE #{table}
      SET key = '#{@new_config_key}', updated_at = timezone('UTC', now())
      WHERE key = '#{@old_config_key}';
    END
    $$
    """
  end

  defp rename_columns(table, pairs) do
    Enum.each(pairs, fn {old_name, new_name} ->
      execute("ALTER TABLE #{table} RENAME COLUMN #{old_name} TO #{new_name}")
    end)
  end

  defp rename_constraints(table, pairs) do
    Enum.each(pairs, fn {old_name, new_name} ->
      execute("ALTER TABLE #{table} RENAME CONSTRAINT #{old_name} TO #{new_name}")
    end)
  end

  defp rename_indexes(pairs) do
    Enum.each(pairs, fn {old_name, new_name} ->
      execute("ALTER INDEX #{old_name} RENAME TO #{new_name}")
    end)
  end

  defp validate_table!(table) do
    if is_binary(table) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, table) do
      table
    else
      raise ArgumentError, "invalid migration table name"
    end
  end
end
