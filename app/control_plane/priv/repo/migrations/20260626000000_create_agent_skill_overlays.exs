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

    comment_table(
      :agent_skill_overlays,
      "Per-agent skill overlay documents authored after built-in sync."
    )

    comment_columns(:agent_skill_overlays, %{
      agent_uid: "Agent principal that owns the overlay.",
      skill_name: "Skill whose overlay is being customized.",
      overlay_json: "Structured overlay content applied on top of the base skill.",
      content_hash: "Hash of the overlay JSON projection.",
      deleted_at: "Soft-delete marker that removes the overlay from the active skill view."
    })
  end

  defp comment_table(table, comment) do
    execute(
      "COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}",
      "COMMENT ON TABLE #{identifier(table)} IS NULL"
    )
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute(
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}",
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS NULL"
    )
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
