defmodule Ankole.Repo.Migrations.DisablePageSearchMutableSegments do
  use Ecto.Migration

  # `pg_search` re-tokenizes every row of a mutable segment on each search, so
  # one large recent Page slowed every tenant's searches. With the option at 0,
  # each write tokenizes its own row once and the next write flushes the rows
  # still waiting in the mutable segment.
  def up do
    execute "ALTER INDEX page_search_documents_bm25_idx SET (mutable_segment_rows = 0)"
  end

  def down do
    execute "ALTER INDEX page_search_documents_bm25_idx RESET (mutable_segment_rows)"
  end
end
