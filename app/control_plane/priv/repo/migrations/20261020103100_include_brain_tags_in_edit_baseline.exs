defmodule Ankole.Repo.Migrations.IncludeBrainTagsInEditBaseline do
  use Ecto.Migration

  def up do
    alter table(:brain_object_versions) do
      add :tags, {:array, :text}, null: false, default: []
    end

    flush()
    rehash(nil)
  end

  def down do
    raise Ecto.MigrationError, message: "the Brain tag edit baseline cannot be downgraded"
  end

  defp rehash(after_id) do
    rows =
      repo().query!(
        """
        SELECT o.id, o.title, o.body, o.meta, o.subtype, o.effective_date,
          ARRAY(SELECT t.tag FROM brain_tags t
            WHERE t.tenant_id = o.tenant_id AND t.object_slug = o.slug)
        FROM brain_objects o
        WHERE ($1::uuid IS NULL OR o.id > $1)
          AND EXISTS (SELECT 1 FROM brain_tags t
            WHERE t.tenant_id = o.tenant_id AND t.object_slug = o.slug)
        ORDER BY o.id LIMIT 1000
        """,
        [after_id]
      ).rows

    Enum.each(rows, fn [id, title, body, meta, subtype, effective_date, tags] ->
      # Freeze the content encoding for replay on a new site.
      canonical_meta =
        meta
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> inspect(limit: :infinity, printable_limit: :infinity)

      tags = tags |> Enum.sort() |> inspect(limit: :infinity, printable_limit: :infinity)

      hash =
        Ankole.Kernel.xxh3_128_hex(
          "#{title}\u0000#{body}\u0000#{canonical_meta}\u0000#{subtype}\u0000#{effective_date}\u0000tags:#{tags}"
        )

      repo().query!("UPDATE brain_objects SET content_hash = $2 WHERE id = $1", [id, hash])
    end)

    case List.last(rows) do
      nil -> :ok
      [id | _fields] -> rehash(id)
    end
  end
end
