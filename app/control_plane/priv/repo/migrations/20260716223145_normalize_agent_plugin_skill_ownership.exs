defmodule Ankole.Repo.Migrations.NormalizeAgentPluginSkillOwnership do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE agent_skills DROP CONSTRAINT IF EXISTS agent_skills_agent_plugin_ownership"
    )

    execute("UPDATE agent_skills SET source_kind = 'builtin' WHERE source_kind = 'agent_plugin'")

    drop_if_exists(constraint(:agent_skills, :agent_skills_source_kind_check))

    create(
      constraint(:agent_skills, :agent_skills_source_kind_check,
        check: "source_kind IN ('builtin', 'installed')"
      )
    )
  end

  def down do
    drop(constraint(:agent_skills, :agent_skills_source_kind_check))

    create(
      constraint(:agent_skills, :agent_skills_source_kind_check,
        check: "source_kind IN ('builtin', 'installed', 'agent_plugin')"
      )
    )

    execute(
      "UPDATE agent_skills SET source_kind = 'agent_plugin' WHERE agent_plugin_id IS NOT NULL"
    )

    create(
      constraint(:agent_skills, :agent_skills_agent_plugin_ownership,
        check:
          "(source_kind = 'agent_plugin' AND agent_plugin_id IS NOT NULL) OR " <>
            "(source_kind <> 'agent_plugin' AND agent_plugin_id IS NULL)"
      )
    )
  end
end
