defmodule Ankole.Repo.Migrations.BrainClaimsUntilDateAsDate do
  use Ecto.Migration

  # `until_date` gates a Take into due-date grading, so it is a date and the
  # database compares it as one. A stored `YYYY-MM-DD` text becomes that date.
  # Any other stored text was never gradable and becomes NULL, which the
  # grader reads as "no due date". An impossible calendar date in the
  # `YYYY-MM-DD` form fails the migration and names the row for manual repair.
  #
  # The type change rewrites the table, and the pg_search BM25 index does not
  # survive a rewrite, so the index is dropped first and created again with
  # the initial tokenizer. `Ankole.Brain.SearchIndexes.ensure_current/0`
  # rebuilds it with a different configured tokenizer on the next Brain tick.
  def up do
    execute("DROP INDEX IF EXISTS brain_claims_bm25_idx")

    execute("""
    ALTER TABLE brain_claims
    ALTER COLUMN until_date TYPE date
    USING (
      CASE
        WHEN until_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN until_date::date
        ELSE NULL
      END
    )
    """)

    execute(create_bm25_index_sql())
  end

  def down do
    execute("DROP INDEX IF EXISTS brain_claims_bm25_idx")

    execute("""
    ALTER TABLE brain_claims
    ALTER COLUMN until_date TYPE text
    USING to_char(until_date, 'YYYY-MM-DD')
    """)

    execute(create_bm25_index_sql())
  end

  defp create_bm25_index_sql do
    """
    CREATE INDEX brain_claims_bm25_idx
    ON brain_claims
    USING bm25 (id, (claim::pdb.icu))
    WITH (key_field='id')
    """
  end
end
