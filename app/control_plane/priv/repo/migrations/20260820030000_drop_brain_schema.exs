defmodule Ankole.Repo.Migrations.DropBrainSchema do
  @moduledoc false

  use Ecto.Migration

  # Retires the Brain long-term-memory schema ahead of a from-scratch rewrite.
  # Table order is FK-safe: brain_entry_relations and brain_block_citations
  # reference brain_entries / brain_entry_blocks and must go first;
  # brain_entry_blocks itself references brain_entries (composite FK) and
  # must go before it. brain_audit_log, brain_episodes, brain_cursors, and
  # brain_retained_sources carry no FK from another brain table.
  #
  # `20260720000001_implement_brain_v2_storage.exs` replaced the guard
  # trigger/function pair migration 1 created for both
  # brain_entry_relations and brain_retained_sources, so the names dropped
  # here are the V2 names, not the original ones. Dropping a table drops its
  # own triggers automatically; the guard functions are separate objects and
  # need an explicit drop once nothing references them.
  def up do
    drop table(:brain_entry_relations)
    drop table(:brain_block_citations)
    drop table(:brain_audit_log)
    drop table(:brain_entry_blocks)
    drop table(:brain_entries)
    drop table(:brain_episodes)
    drop table(:brain_cursors)
    drop table(:brain_retained_sources)

    execute("DROP FUNCTION IF EXISTS brain_validate_entry_relation_scope()")
    execute("DROP FUNCTION IF EXISTS guard_brain_retained_source_update()")

    execute("DROP TYPE IF EXISTS brain_cursor_scope_kind")
    execute("DROP TYPE IF EXISTS brain_embedding_state")
    execute("DROP TYPE IF EXISTS brain_author_kind")

    execute("DROP INDEX IF EXISTS signal_gateway_entries_brain_bm25_index")

    # No other migration creates a `USING bm25` index or a vector/halfvec
    # column, so both extensions are Brain-only and safe to drop.
    execute("DROP EXTENSION IF EXISTS pg_search")
    execute("DROP EXTENSION IF EXISTS vector")

    execute("DELETE FROM principals WHERE uid = 'brain-shared'")
  end

  def down do
    raise "Brain schema cannot be restored by migration; re-run the Brain V1-V3 migrations against a fresh database if the schema is genuinely needed back"
  end
end
