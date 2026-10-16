defmodule Ankole.Repo.Migrations.CoverBrainEditFieldsInContentHash do
  use Ecto.Migration

  def up, do: rehash(nil)

  def down do
    raise Ecto.MigrationError, message: "the complete Brain edit baseline cannot be downgraded"
  end

  defp rehash(after_id) do
    rows =
      repo().query!(
        """
        SELECT id, title, body, meta, subtype, effective_date
        FROM brain_objects
        WHERE $1::uuid IS NULL OR id > $1
        ORDER BY id
        LIMIT 1000
        """,
        [after_id]
      ).rows

    Enum.each(rows, fn [id, title, body, meta, subtype, effective_date] ->
      # Freeze the encoding here; later changes to the domain must not change
      # the meaning of this migration when a new site replays it.
      canonical_meta =
        meta
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> inspect(limit: :infinity, printable_limit: :infinity)

      hash =
        Ankole.Kernel.xxh3_128_hex(
          "#{title}\u0000#{body}\u0000#{canonical_meta}\u0000#{subtype}\u0000#{effective_date}"
        )

      repo().query!("UPDATE brain_objects SET content_hash = $2 WHERE id = $1", [id, hash])
    end)

    case List.last(rows) do
      nil -> :ok
      [id | _fields] -> rehash(id)
    end
  end
end
