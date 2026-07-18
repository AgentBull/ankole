defmodule Ankole.Repo.Migrations.AddAgentPluginsAndBackgroundAgentJobV2 do
  use Ecto.Migration

  @legacy_snapshot_key "background_agent_job_v1"

  def up do
    execute(require_no_live_jobs_sql("upgrade"))
    execute(legacy_job_v2_guard_sql())

    create table(:agent_plugin_overrides, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :agent_uid,
        references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:agent_plugin_id, :text, null: false)
      add(:enabled, :boolean, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:agent_plugin_overrides, [:agent_uid, :agent_plugin_id],
        name: :agent_plugin_overrides_agent_plugin_index
      )
    )

    create(
      constraint(:agent_plugin_overrides, :agent_plugin_overrides_agent_plugin_id_format,
        check: "agent_plugin_id ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )

    drop(index(:agent_skills, [:agent_uid, :enabled], name: :agent_skills_agent_enabled_index))
    rename(table(:agent_skills), :enabled, to: :enabled_override)

    alter table(:agent_skills) do
      modify(:enabled_override, :boolean, null: true)
      add(:agent_plugin_id, :text)
    end

    execute(
      "UPDATE agent_skills SET enabled_override = NULL WHERE enabled_override = default_enabled"
    )

    create(
      index(:agent_skills, [:agent_uid, :enabled_override],
        name: :agent_skills_agent_enabled_override_index,
        where: "enabled_override IS NOT NULL"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_agent_plugin_id_format,
        check: "agent_plugin_id IS NULL OR agent_plugin_id ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )

    alter table(:background_agent_jobs) do
      add(:agent_plugin_ids, {:array, :text}, null: false, default: [])
      add(:skill_names, {:array, :text}, null: false, default: [])
      add(:workspace_mounts, :map)
      add(:model, :text)
      add(:reasoning_effort, :text)
    end

    execute(legacy_job_v2_backfill_sql())

    alter table(:background_agent_jobs) do
      modify(:workspace_mounts, :map, null: false)
    end

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_agent_plugin_ids_valid,
        check:
          "array_position(agent_plugin_ids, NULL) IS NULL AND cardinality(agent_plugin_ids) <= 16"
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_skill_names_valid,
        check: "array_position(skill_names, NULL) IS NULL AND cardinality(skill_names) <= 256"
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_workspace_mounts_array,
        check:
          "jsonb_typeof(workspace_mounts) = 'array' AND jsonb_array_length(workspace_mounts) BETWEEN 1 AND 16"
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_model_present,
        check: "model IS NULL OR length(btrim(model)) > 0"
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_reasoning_effort_check,
        check:
          "reasoning_effort IS NULL OR reasoning_effort IN ('minimal', 'low', 'medium', 'high', 'xhigh')"
      )
    )

    drop_if_exists(
      index(:background_agent_jobs, [:source_job_id],
        name: :background_agent_jobs_source_job_index
      )
    )

    drop_if_exists(
      index(:background_agent_jobs, [:completed_at],
        name: :background_agent_jobs_research_workspace_cleanup_index
      )
    )

    drop(constraint(:background_agent_jobs, :background_agent_jobs_research_contract_check))
    drop(constraint(:background_agent_jobs, :background_agent_jobs_workspace_retention_check))
    drop(constraint(:background_agent_jobs, :background_agent_jobs_runtime_check))

    alter table(:background_agent_jobs) do
      remove(:actual_outcome)
      remove(:source_job_id)
      remove(:mode)
      remove(:runtime)
      remove(:workdir)
      remove(:workspace_retention_days)
      remove(:workspace_cleaned_at)
    end

    execute(rename_rendered_fetch_ttl_up_sql())
  end

  def down do
    raise "BackgroundAgentJob V2 cannot be downgraded: V1 runtime and workspace fields are retained only as untrusted informational metadata, not schema-private restoration provenance"
  end

  @doc false
  def legacy_snapshot_key, do: @legacy_snapshot_key

  @doc false
  def legacy_job_v2_guard_sql(table \\ "background_agent_jobs") do
    table = validate_table!(table)

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{table}
        WHERE metadata ? '#{@legacy_snapshot_key}'
      ) THEN
        RAISE EXCEPTION
          'BackgroundAgentJob V2 migration snapshot key already exists'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """
  end

  @doc false
  def legacy_job_v2_backfill_sql(table \\ "background_agent_jobs") do
    table = validate_table!(table)

    """
    UPDATE #{table}
    SET
      metadata = metadata || jsonb_build_object(
        '#{@legacy_snapshot_key}',
        jsonb_strip_nulls(jsonb_build_object(
          'runtime', runtime,
          'runtime_thread_id', runtime_thread_id,
          'workdir', workdir,
          'mode', mode,
          'source_job_id', source_job_id,
          'actual_outcome', actual_outcome,
          'workspace_retention_days', workspace_retention_days,
          'workspace_cleaned_at', workspace_cleaned_at,
          'v2_resume_supported', false,
          'v2_resume_disabled_reason', 'pre_v2_runtime_state_is_not_resumable',
          'v2_workspace_mount_materialized', false
        ))
      ),
      agent_plugin_ids = CASE
        WHEN runtime = 'deep_research' THEN ARRAY['deep-research']::text[]
        ELSE ARRAY[]::text[]
      END,
      skill_names = ARRAY[]::text[],
      workspace_mounts = jsonb_build_array(jsonb_build_object(
        'id', 'workspace',
        'source', '/workspace/user-files/background-agent-jobs/' || id::text || '/workspace',
        'access', 'read_write'
      )),
      runtime_thread_id = NULL
    """
  end

  defp require_no_live_jobs_sql(direction) do
    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM background_agent_jobs
        WHERE status NOT IN ('succeeded', 'failed', 'stopped')
      ) THEN
        RAISE EXCEPTION
          'BackgroundAgentJob V2 #{direction} requires no non-terminal jobs'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """
  end

  defp validate_table!(table) do
    if is_binary(table) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, table) do
      table
    else
      raise ArgumentError, "invalid migration table name"
    end
  end

  defp rename_rendered_fetch_ttl_up_sql do
    rename_app_config_key_sql(
      "worker.local_browser_idle_ttl_ms",
      "worker.rendered_fetch_idle_ttl_ms"
    )
  end

  defp rename_app_config_key_sql(from, to) do
    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM app_configurations AS source
        JOIN app_configurations AS target ON target.scope = source.scope
        WHERE source.key = '#{from}' AND target.key = '#{to}'
      ) THEN
        RAISE EXCEPTION
          'AppConfigure key rename #{from} -> #{to} has conflicting scoped rows'
          USING ERRCODE = 'unique_violation';
      END IF;

      UPDATE app_configurations
      SET key = '#{to}', updated_at = CURRENT_TIMESTAMP
      WHERE key = '#{from}';
    END
    $$
    """
  end
end
