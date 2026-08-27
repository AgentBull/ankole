defmodule Ankole.Repo.Migrations.CreateAgentSkillLessons do
  use Ecto.Migration

  # Replaces the free-text agent_skill_overlays blob with leased, per-item
  # skill lessons. Active overlay rows become human lesson rows so operator
  # guidance survives the swap; the overlay table is dropped in the same
  # migration because nothing reads it afterwards.
  def up do
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

  def down do
    raise Ecto.MigrationError,
      message: "agent_skill_overlays cannot be rebuilt from lesson rows"
  end
end
