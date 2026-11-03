defmodule Ankole.Repo.Migrations.UnifyAgentContracts do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE agent_skills DROP CONSTRAINT agent_skills_source_kind_check")

    execute(
      "ALTER TABLE agent_skills ADD CONSTRAINT agent_skills_source_kind_check CHECK (source_kind IN ('builtin', 'shared', 'installed'))"
    )

    # Data is migrated after the Page ownership schema is available.
  end

  def down,
    do:
      raise(
        "Agent contracts live on Pod pages; restore a database backup to reverse this migration"
      )
end
