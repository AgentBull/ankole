defmodule Ankole.Repo.Migrations.AddAgentDesignDocument do
  use Ecto.Migration

  def up do
    drop constraint(
           :agent_library_container_entries,
           :agent_library_container_entries_source_kind_check
         )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_source_kind_check,
             check: "source_kind IN ('soul', 'mission', 'design')"
           )

    execute(
      "COMMENT ON TABLE agent_library_container_entries IS 'Per-agent runtime documents for SOUL.md, MISSION.md, and DESIGN.md.'"
    )

    execute(
      "COMMENT ON COLUMN agent_library_container_entries.source_kind IS 'Agent document kind: soul, mission, or design.'"
    )
  end

  def down do
    execute("DELETE FROM agent_library_container_entries WHERE source_kind = 'design'")

    drop constraint(
           :agent_library_container_entries,
           :agent_library_container_entries_source_kind_check
         )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_source_kind_check,
             check: "source_kind IN ('soul', 'mission')"
           )

    execute(
      "COMMENT ON TABLE agent_library_container_entries IS 'Per-agent library entries for worker-visible SOUL.md and MISSION.md files.'"
    )

    execute(
      "COMMENT ON COLUMN agent_library_container_entries.source_kind IS 'Persona file kind: soul or mission.'"
    )
  end
end
