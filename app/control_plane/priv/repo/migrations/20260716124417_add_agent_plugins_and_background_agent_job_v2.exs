defmodule Ankole.Repo.Migrations.AddAgentPluginsAndBackgroundAgentJobV2 do
  use Ecto.Migration

  def up do
    execute(require_no_live_jobs_sql("upgrade"))
    execute("DELETE FROM background_agent_jobs")

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
      add(:workspace_mounts, :map, null: false)
      add(:model, :text)
      add(:reasoning_effort, :text)
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
    execute(require_no_live_jobs_sql("downgrade"))
    execute("DELETE FROM background_agent_jobs")
    execute(rename_rendered_fetch_ttl_down_sql())

    alter table(:background_agent_jobs) do
      add(:runtime, :text, null: false, default: "task_worker")
      add(:mode, :text)

      add(
        :source_job_id,
        references(:background_agent_jobs, type: :uuid, on_delete: :restrict)
      )

      add(:actual_outcome, :boolean)
      add(:workdir, :text, null: false)
      add(:workspace_retention_days, :integer)
      add(:workspace_cleaned_at, :utc_datetime_usec)
    end

    create(
      index(:background_agent_jobs, [:source_job_id],
        name: :background_agent_jobs_source_job_index,
        where: "source_job_id IS NOT NULL"
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_runtime_check,
        check: "runtime IN ('task_worker', 'deep_research')"
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_research_contract_check,
        check: """
        (runtime = 'task_worker' AND mode IS NULL AND source_job_id IS NULL AND actual_outcome IS NULL)
        OR
        (runtime = 'deep_research' AND mode IN ('general', 'forecast', 'retrospect') AND
          ((mode = 'retrospect' AND source_job_id IS NOT NULL) OR
           (mode <> 'retrospect' AND source_job_id IS NULL AND actual_outcome IS NULL)))
        """
      )
    )

    create(
      constraint(:background_agent_jobs, :background_agent_jobs_workspace_retention_check,
        check:
          "(runtime = 'task_worker' AND workspace_retention_days IS NULL) OR (runtime = 'deep_research' AND workspace_retention_days BETWEEN 1 AND 3650)"
      )
    )

    create(
      index(:background_agent_jobs, [:completed_at],
        name: :background_agent_jobs_research_workspace_cleanup_index,
        where:
          "runtime = 'deep_research' AND workspace_cleaned_at IS NULL AND completed_at IS NOT NULL"
      )
    )

    drop(constraint(:background_agent_jobs, :background_agent_jobs_reasoning_effort_check))
    drop(constraint(:background_agent_jobs, :background_agent_jobs_model_present))
    drop(constraint(:background_agent_jobs, :background_agent_jobs_workspace_mounts_array))
    drop(constraint(:background_agent_jobs, :background_agent_jobs_skill_names_valid))
    drop(constraint(:background_agent_jobs, :background_agent_jobs_agent_plugin_ids_valid))

    alter table(:background_agent_jobs) do
      remove(:reasoning_effort)
      remove(:model)
      remove(:workspace_mounts)
      remove(:skill_names)
      remove(:agent_plugin_ids)
    end

    drop(constraint(:agent_skills, :agent_skills_agent_plugin_id_format))

    drop(
      index(:agent_skills, [:agent_uid, :enabled_override],
        name: :agent_skills_agent_enabled_override_index
      )
    )

    execute(
      "UPDATE agent_skills SET enabled_override = default_enabled WHERE enabled_override IS NULL"
    )

    alter table(:agent_skills) do
      remove(:agent_plugin_id)
      modify(:enabled_override, :boolean, null: false)
    end

    rename(table(:agent_skills), :enabled_override, to: :enabled)

    create(index(:agent_skills, [:agent_uid, :enabled], name: :agent_skills_agent_enabled_index))

    drop(table(:agent_plugin_overrides))
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

  defp rename_rendered_fetch_ttl_up_sql do
    rename_app_config_key_sql(
      "worker.local_browser_idle_ttl_ms",
      "worker.rendered_fetch_idle_ttl_ms"
    )
  end

  defp rename_rendered_fetch_ttl_down_sql do
    rename_app_config_key_sql(
      "worker.rendered_fetch_idle_ttl_ms",
      "worker.local_browser_idle_ttl_ms"
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
