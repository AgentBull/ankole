defmodule Ankole.Repo.Migrations.UpgradeAgentsAndLibraryV1 do
  @moduledoc false

  use Ecto.Migration

  # BrainV3 Stage 0: every Agent gets a required owner Principal and a group
  # memory disclosure mode. Existing Agents are backfilled with the earliest
  # admin human as owner. The retired embedding/rerank Agent model-profile
  # slots are removed from stored options because Brain owns those models
  # instance-wide through brain.* AppConfigure keys.
  def up do
    execute("""
    UPDATE principals
    SET display_name = uid,
        updated_at = NOW()
    WHERE type = 'agent'
      AND (display_name IS NULL OR btrim(display_name) = '')
    """)

    create constraint(:principals, :principals_agent_display_name_present,
             check: "type <> 'agent' OR (display_name IS NOT NULL AND btrim(display_name) <> '')"
           )

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

    create_skill_lessons()
  end

  def down do
    raise Ecto.MigrationError,
      message: "the pre-v1 Agent and Skill Overlay state cannot be restored after the v1 upgrade"
  end

  defp create_skill_lessons do
    create table(:agent_skill_lessons, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :agent_uid,
        references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:skill_name, :text, null: false)
      add(:content, :text, null: false)
      add(:author_kind, :text, null: false)

      add(
        :author_uid,
        references(:principals, column: :uid, type: :text, on_delete: :nilify_all)
      )

      add(:evidence_job_ids, :jsonb, null: false, default: "[]")
      add(:checked_release, :text)
      add(:checked_skill_hash, :text)
      add(:review_after, :utc_datetime_usec)
      add(:retired_at, :utc_datetime_usec)
      add(:retire_reason, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(:agent_skill_lessons, [:agent_uid, :skill_name],
        where: "retired_at IS NULL",
        name: :agent_skill_lessons_active_idx
      )
    )

    create(
      index(:agent_skill_lessons, [:review_after],
        where: "retired_at IS NULL AND review_after IS NOT NULL",
        name: :agent_skill_lessons_docket_idx
      )
    )

    create(
      constraint(:agent_skill_lessons, :agent_skill_lessons_author_kind,
        check: "author_kind IN ('dreaming', 'human')"
      )
    )

    create(
      constraint(:agent_skill_lessons, :agent_skill_lessons_skill_name_format,
        check: "skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )

    create(
      constraint(:agent_skill_lessons, :agent_skill_lessons_content_present,
        check: "length(btrim(content)) > 0"
      )
    )

    create(
      constraint(:agent_skill_lessons, :agent_skill_lessons_evidence_array,
        check: "jsonb_typeof(evidence_job_ids) = 'array'"
      )
    )

    create(
      constraint(:agent_skill_lessons, :agent_skill_lessons_retire_shape,
        check: """
        ((retired_at IS NULL) = (retire_reason IS NULL))
        AND (retire_reason IS NULL OR retire_reason IN ('human_revoked', 'lapsed', 'obsolete'))
        """
      )
    )

    create(
      constraint(:agent_skill_lessons, :agent_skill_lessons_lease_shape,
        check: """
        (author_kind = 'dreaming'
          AND review_after IS NOT NULL
          AND checked_release IS NOT NULL
          AND checked_skill_hash IS NOT NULL
          AND jsonb_array_length(evidence_job_ids) > 0)
        OR (author_kind = 'human' AND review_after IS NULL)
        """
      )
    )

    execute("""
    INSERT INTO agent_skill_lessons
      (id, agent_uid, skill_name, content, author_kind, evidence_job_ids,
       inserted_at, updated_at)
    SELECT
      overlay.id,
      overlay.agent_uid,
      overlay.skill_name,
      overlay.overlay_json->>'text',
      'human',
      '[]'::jsonb,
      overlay.updated_at,
      overlay.updated_at
    FROM agent_skill_overlays AS overlay
    WHERE overlay.deleted_at IS NULL
      AND length(btrim(coalesce(overlay.overlay_json->>'text', ''))) > 0
    """)

    drop(table(:agent_skill_overlays))
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
