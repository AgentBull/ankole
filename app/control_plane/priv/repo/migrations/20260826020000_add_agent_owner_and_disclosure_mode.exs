defmodule Ankole.Repo.Migrations.AddAgentOwnerAndDisclosureMode do
  @moduledoc false

  use Ecto.Migration

  # BrainV3 Stage 0: every Agent gets a required owner Principal and a group
  # memory disclosure mode. Existing Agents are backfilled with the earliest
  # admin human as owner. The retired embedding/rerank Agent model-profile
  # slots are removed from stored options because Brain owns those models
  # instance-wide through brain.* AppConfigure keys.
  def up do
    alter table(:agents) do
      add :owner_principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :restrict)

      add :group_memory_disclosure_mode, :text, null: false, default: "strict"
    end

    create constraint(:agents, :agents_group_memory_disclosure_mode_check,
             check: "group_memory_disclosure_mode IN ('strict', 'relaxed')"
           )

    # The earliest admin member becomes the owner of every existing Agent.
    # Setup creates the admin group before any Agent can exist, so a NULL
    # result with existing Agents fails the NOT NULL change loudly.
    execute("""
    UPDATE agents SET owner_principal_uid = (
      SELECT m.principal_uid
      FROM principal_group_memberships m
      JOIN principal_groups g ON g.id = m.group_id
      JOIN principals p ON p.uid = m.principal_uid
      WHERE g.name = 'admin'
      ORDER BY p.inserted_at ASC, p.uid ASC
      LIMIT 1
    )
    """)

    execute("ALTER TABLE agents ALTER COLUMN owner_principal_uid SET NOT NULL")

    create index(:agents, [:owner_principal_uid])

    comment_columns(:agents, %{
      owner_principal_uid: "Principal that owns this Agent; required.",
      group_memory_disclosure_mode:
        "How group-chat disclosure filters recalled Brain knowledge: strict checks every present member, relaxed checks only the asker."
    })

    execute("""
    UPDATE agents
    SET options = jsonb_set(
      options,
      '{ai_agent,models}',
      (options->'ai_agent'->'models') - 'embedding' - 'rerank'
    )
    WHERE options->'ai_agent'->'models' ?| array['embedding','rerank']
    """)

    # ConfidentialityPolicy.md joins the operator-editable Agent documents.
    # Existing Agents need no backfill row: reads fall back to the bundled
    # template until the first write materializes a row.
    drop constraint(
           :agent_library_container_entries,
           :agent_library_container_entries_source_kind_check
         )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_source_kind_check,
             check: "source_kind IN ('soul', 'mission', 'design', 'confidentiality_policy')"
           )

    execute(
      "COMMENT ON COLUMN agent_library_container_entries.source_kind IS 'Agent document kind: soul, mission, design, or confidentiality_policy.'"
    )
  end

  def down do
    execute(
      "DELETE FROM agent_library_container_entries WHERE source_kind = 'confidentiality_policy'"
    )

    drop constraint(
           :agent_library_container_entries,
           :agent_library_container_entries_source_kind_check
         )

    create constraint(
             :agent_library_container_entries,
             :agent_library_container_entries_source_kind_check,
             check: "source_kind IN ('soul', 'mission', 'design')"
           )

    drop constraint(:agents, :agents_group_memory_disclosure_mode_check)

    alter table(:agents) do
      remove :owner_principal_uid
      remove :group_memory_disclosure_mode
    end

    # Removed embedding/rerank model-profile slots are not restored; Brain
    # owns those models after this migration.
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} ->
      execute(
        "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}"
      )
    end)
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
