defmodule Ankole.Repo.Migrations.CreateAgentSkillOverlays do
  use Ecto.Migration

  def change do
    create table(:agent_skill_overlays, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:skill_name, :text, null: false)

      add(:overlay_json, :map, null: false, default: %{})
      add(:content_hash, :text, null: false)
      add(:deleted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:agent_skill_overlays, [:agent_uid, :skill_name],
        name: :agent_skill_overlays_active_skill_index,
        where: "deleted_at IS NULL"
      )
    )

    create(
      constraint(:agent_skill_overlays, :agent_skill_overlays_skill_name_format,
        check: "skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'"
      )
    )

    create(
      constraint(:agent_skill_overlays, :agent_skill_overlays_overlay_object,
        check: "jsonb_typeof(overlay_json) = 'object'"
      )
    )

    create(
      constraint(:agent_skill_overlays, :agent_skill_overlays_content_hash_present,
        check: "length(btrim(content_hash)) > 0"
      )
    )
  end
end
