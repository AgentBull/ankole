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

  @session_columns [
    {"actor_events", "session_id"},
    {"actor_event_deliveries", "session_id"},
    {"actor_session_worker_assignments", "session_id"},
    {"actor_session_activations", "session_id"},
    {"actor_cron_schedules", "session_id"},
    {"actor_scheduled_events", "session_id"},
    {"signal_gateway_inbound_batches", "session_id"},
    {"ai_gateway_conversations", "conversation_key"}
  ]

  def up do
    assert_no_live_rows("subagent_delegations")

    execute("ALTER TABLE subagent_delegations RENAME TO background_agent_jobs")
    execute("ALTER TABLE subagent_delegation_turns RENAME TO background_agent_job_turns")

    rename_columns("background_agent_jobs", @job_columns)
    rename_columns("background_agent_job_turns", @turn_columns)
    rename_constraints("background_agent_jobs", @job_constraints)
    rename_indexes(@job_indexes)
    rename_constraints("background_agent_job_turns", @turn_constraints)
    rename_indexes(@turn_indexes)

    rewrite_actor_events_up()
    rewrite_session_keys("subagent:", "job:")
    rewrite_job_metadata("brain_parent_conversation_id", "brain_owner_conversation_id")
    migrate_config_key(@old_config_key, @new_config_key)
  end

  def down do
    assert_no_live_rows("background_agent_jobs")

    migrate_config_key(@new_config_key, @old_config_key)
    rewrite_job_metadata("brain_owner_conversation_id", "brain_parent_conversation_id")
    rewrite_session_keys("job:", "subagent:")
    rewrite_actor_events_down()

    rename_indexes(reverse(@turn_indexes))
    rename_constraints("background_agent_job_turns", reverse(@turn_constraints))
    rename_indexes(reverse(@job_indexes))
    rename_constraints("background_agent_jobs", reverse(@job_constraints))
    rename_columns("background_agent_job_turns", reverse(@turn_columns))
    rename_columns("background_agent_jobs", reverse(@job_columns))

    execute("ALTER TABLE background_agent_job_turns RENAME TO subagent_delegation_turns")
    execute("ALTER TABLE background_agent_jobs RENAME TO subagent_delegations")
  end

  defp assert_no_live_rows(table) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{table}
        WHERE status IN ('queued', 'running', 'waiting_on_user')
      ) THEN
        RAISE EXCEPTION
          'BackgroundAgentJob naming migration requires zero non-terminal jobs';
      END IF;
    END
    $$
    """)
  end

  defp rewrite_actor_events_up do
    Enum.each(actor_event_rewrite_sqls(:up), fn statement -> execute(statement) end)
  end

  defp rewrite_actor_events_down do
    Enum.each(actor_event_rewrite_sqls(:down), fn statement -> execute(statement) end)
  end

  @doc false
  def actor_event_rewrite_sqls(direction, table \\ "actor_events")

  def actor_event_rewrite_sqls(:up, table) do
    table = validate_table!(table)

    build_actor_events_rewrite_sqls(
      table,
      "subagent.delegation.",
      "background_agent_job.",
      "delegation_id",
      "job_id",
      "parent_session_id",
      "owner_session_id",
      "subagent_delegation:",
      "background_agent_job:",
      "control-plane://background-agent-job",
      "subagent-delegation:",
      "background-agent-job:",
      "subagent_delegation:",
      "background_agent_job:"
    )
  end

  def actor_event_rewrite_sqls(:down, table) do
    table = validate_table!(table)

    build_actor_events_rewrite_sqls(
      table,
      "background_agent_job.",
      "subagent.delegation.",
      "job_id",
      "delegation_id",
      "owner_session_id",
      "parent_session_id",
      "background_agent_job:",
      "subagent_delegation:",
      "control-plane://subagent/delegation",
      "background-agent-job:",
      "subagent-delegation:",
      "background_agent_job:",
      "subagent_delegation:"
    )
  end

  defp build_actor_events_rewrite_sqls(
         table,
         old_type_prefix,
         new_type_prefix,
         old_id_key,
         new_id_key,
         old_owner_key,
         new_owner_key,
         old_source_prefix,
         new_source_prefix,
         new_source,
         old_subject_prefix,
         new_subject_prefix,
         old_source_event_id_prefix,
         new_source_event_id_prefix
       ) do
    [
      """
      UPDATE #{table}
      SET
        type = replace(type, '#{old_type_prefix}', '#{new_type_prefix}'),
        payload =
          payload || jsonb_build_object(
            'data',
              (
                coalesce(jsonb_extract_path(payload, 'data'), '{}'::jsonb) -
                  '#{old_id_key}'::text - '#{old_owner_key}'::text
              ) ||
                jsonb_build_object(
                  '#{new_id_key}',
                  jsonb_extract_path(payload, 'data', '#{old_id_key}')
                ) ||
                CASE
                  WHEN jsonb_extract_path(payload, 'data', '#{old_owner_key}') IS NOT NULL THEN
                    jsonb_build_object(
                      '#{new_owner_key}',
                      jsonb_extract_path(payload, 'data', '#{old_owner_key}')
                    )
                  ELSE '{}'::jsonb
                END,
            'id',
              replace(
                jsonb_extract_path_text(payload, 'id'),
                '#{old_source_prefix}',
                '#{new_source_prefix}'
              ),
            'source', '#{new_source}',
            'subject',
              replace(
                jsonb_extract_path_text(payload, 'subject'),
                '#{old_subject_prefix}',
                '#{new_subject_prefix}'
              ),
            'type',
              replace(
                jsonb_extract_path_text(payload, 'type'),
                '#{old_type_prefix}',
                '#{new_type_prefix}'
              )
          )
      WHERE type IN (
        '#{old_type_prefix}dispatch',
        '#{old_type_prefix}completed',
        '#{old_type_prefix}failed',
        '#{old_type_prefix}waiting'
      )
      """,
      """
      UPDATE #{table}
      SET source_event_id = regexp_replace(
        source_event_id,
        '^#{old_source_event_id_prefix}',
        '#{new_source_event_id_prefix}'
      )
      WHERE source_event_id LIKE '#{old_source_event_id_prefix}%'
      """
    ]
  end

  defp validate_table!(table) do
    if is_binary(table) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, table) do
      table
    else
      raise ArgumentError, "invalid migration table name"
    end
  end

  defp rewrite_session_keys(old_prefix, new_prefix) do
    Enum.each(@session_columns, fn {table, column} ->
      execute("""
      UPDATE #{table}
      SET #{column} = '#{new_prefix}' || substr(#{column}, #{byte_size(old_prefix) + 1})
      WHERE #{column} LIKE '#{old_prefix}%'
      """)
    end)
  end

  defp migrate_config_key(old_key, new_key) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM app_configurations old_config
        JOIN app_configurations new_config ON new_config.scope = old_config.scope
        WHERE old_config.key = '#{old_key}' AND new_config.key = '#{new_key}'
      ) THEN
        RAISE EXCEPTION
          'Both old and new BackgroundAgentJob AppConfigure keys exist for one scope';
      END IF;
    END
    $$
    """)

    execute("""
    UPDATE app_configurations
    SET key = '#{new_key}', updated_at = timezone('UTC', now())
    WHERE key = '#{old_key}'
    """)
  end

  defp rewrite_job_metadata(old_key, new_key) do
    execute("""
    UPDATE background_agent_jobs
    SET metadata =
      (metadata - '#{old_key}'::text) ||
        jsonb_build_object('#{new_key}', metadata->'#{old_key}')
    WHERE metadata ? '#{old_key}'::text
    """)
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

  defp reverse(pairs), do: Enum.map(pairs, fn {old_name, new_name} -> {new_name, old_name} end)
end
