defmodule Ankole.Repo.Migrations.UnifyAgentSkills do
  use Ecto.Migration

  def up do
    create table(:agent_skills, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:skill_name, :text, null: false)
      add(:source_kind, :text, null: false)
      add(:relative_path, :text, null: false)
      add(:enabled, :boolean, null: false)
      add(:default_enabled, :boolean, null: false)
      add(:description, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:content_hash, :text, null: false)
      add(:synced_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:agent_skills, [:agent_uid, :skill_name],
        name: :agent_skills_agent_skill_index
      )
    )

    create(index(:agent_skills, [:agent_uid, :enabled], name: :agent_skills_agent_enabled_index))

    create(
      constraint(:agent_skills, :agent_skills_skill_name_format,
        check: "skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_source_kind_check,
        check: "source_kind IN ('builtin', 'installed')"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_relative_path_present,
        check: "length(btrim(relative_path)) > 0"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_description_present,
        check: "length(btrim(description)) > 0"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_metadata_object,
        check: "jsonb_typeof(metadata) = 'object'"
      )
    )

    create(
      constraint(:agent_skills, :agent_skills_content_hash_present,
        check: "length(btrim(content_hash)) > 0"
      )
    )

    comment_table(:agent_skills, "Per-agent skill registry used by runtime skill discovery.")

    comment_columns(:agent_skills, %{
      agent_uid: "Agent principal that owns the skill registry row.",
      skill_name: "Agent-visible skill name.",
      source_kind: "Whether the skill comes from built-in repository content or installed files.",
      relative_path: "Path to the skill entrypoint relative to its source root.",
      enabled: "Whether the skill is currently enabled for the agent.",
      default_enabled: "Default enablement from the source before agent overrides.",
      description: "Short skill description shown to operators and workers.",
      metadata: "Skill metadata outside the discovery contract.",
      content_hash: "Hash of the skill entrypoint or synchronized source projection.",
      synced_at: "Time this registry row was last synchronized from its source."
    })
  end

  def down do
    raise "irreversible migration: agent_skills is the skill registry"
  end

  defp comment_table(table, comment) do
    execute("COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}")
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute("COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}")
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
