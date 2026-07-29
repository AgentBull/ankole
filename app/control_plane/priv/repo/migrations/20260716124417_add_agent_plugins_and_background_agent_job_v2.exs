defmodule Ankole.Repo.Migrations.AddAgentPluginsAndBackgroundAgentJobV2 do
  use Ecto.Migration

  def up do
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
      add(:skill_names, {:array, :text}, null: false, default: [])
      add(:workspace_mounts, :map)
      add(:model, :text)
      add(:reasoning_effort, :text)
    end

    alter table(:background_agent_jobs) do
      modify(:workspace_mounts, :map, null: false)
    end

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

    execute(rendered_fetch_config_key_migration_sql())
  end

  def down do
    raise "BackgroundAgentJob V2 cannot be downgraded after the v0.7.0 runtime cutover"
  end

  @doc false
  def rendered_fetch_config_key_migration_sql(table \\ "app_configurations") do
    table = validate_table!(table)

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{table} AS source
        JOIN #{table} AS target ON target.scope = source.scope
        WHERE source.key = 'worker.local_browser_idle_ttl_ms'
          AND target.key = 'worker.rendered_fetch_idle_ttl_ms'
      ) THEN
        RAISE EXCEPTION
          'AppConfigure key rename worker.local_browser_idle_ttl_ms -> worker.rendered_fetch_idle_ttl_ms has conflicting scoped rows'
          USING ERRCODE = 'unique_violation';
      END IF;

      UPDATE #{table}
      SET key = 'worker.rendered_fetch_idle_ttl_ms', updated_at = CURRENT_TIMESTAMP
      WHERE key = 'worker.local_browser_idle_ttl_ms';
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
end
