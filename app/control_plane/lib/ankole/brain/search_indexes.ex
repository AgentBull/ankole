defmodule Ankole.Brain.SearchIndexes do
  @moduledoc """
  Recoverable retrieval-index lifecycle for Brain: the two pg_search BM25
  indexes and the two HNSW ANN indexes.

  The deployment-level tokenizer comes from `brain.search_tokenizer` and maps
  through a fixed whitelist to a pg_search tokenizer expression; the
  configuration value never concatenates into SQL as free text. A tokenizer
  change rebuilds the BM25 indexes. Every index also rebuilds when it is
  missing or PostgreSQL marks it invalid or not ready; the base tables stay
  authoritative.
  """

  alias Ankole.Brain.Config
  alias Ankole.Repo

  @bm25_indexes [
    {"brain_chunks_bm25_idx", "brain_chunks", "chunk_text"},
    {"brain_claims_bm25_idx", "brain_claims", "claim"}
  ]

  # DDL matches the initial migration; a drifted definition would make the
  # rebuilt index differ from a freshly migrated instance.
  @hnsw_indexes [
    {"brain_chunks_embedding_hnsw_idx",
     """
     CREATE INDEX brain_chunks_embedding_hnsw_idx
     ON brain_chunks USING hnsw
       ((subvector(embedding, 1, 4000)::halfvec(4000)) halfvec_cosine_ops)
     WHERE embedding IS NOT NULL
     """},
    {"brain_claims_embedding_hnsw_idx",
     """
     CREATE INDEX brain_claims_embedding_hnsw_idx
     ON brain_claims USING hnsw
       ((subvector(embedding, 1, 4000)::halfvec(4000)) halfvec_cosine_ops)
     WHERE embedding IS NOT NULL
       AND ((claim_type = 'fact' AND expired_at IS NULL)
         OR (claim_type = 'take' AND active = true))
     """}
  ]

  # Fixed whitelist: configuration name to pg_search tokenizer cast.
  @tokenizer_casts %{
    "icu" => "pdb.icu",
    "jieba" => "pdb.jieba",
    "lindera_japanese" => "pdb.lindera('japanese')",
    "lindera_korean" => "pdb.lindera('korean')"
  }

  @doc """
  Ensures every retrieval index exists, is valid, and (for BM25) uses the
  configured tokenizer, rebuilding when a check fails. Returns the actions
  taken.
  """
  @spec ensure_current() :: {:ok, [map()]} | {:error, term()}
  def ensure_current do
    case Map.fetch(@tokenizer_casts, Config.search_tokenizer()) do
      {:ok, cast} ->
        bm25_actions =
          Enum.map(@bm25_indexes, fn {index, table, column} ->
            ensure_bm25_index(index, table, column, cast)
          end)

        hnsw_actions =
          Enum.map(@hnsw_indexes, fn {index, ddl} -> ensure_hnsw_index(index, ddl) end)

        {:ok, bm25_actions ++ hnsw_actions}

      :error ->
        {:error, {:unknown_search_tokenizer, Config.search_tokenizer()}}
    end
  end

  defp ensure_bm25_index(index, table, column, cast) do
    cond do
      index_definition(index) == nil ->
        create_bm25_index(index, table, column, cast)
        %{index: index, action: :created}

      not index_usable?(index) ->
        Repo.query!("DROP INDEX IF EXISTS #{index}")
        create_bm25_index(index, table, column, cast)
        %{index: index, action: :rebuilt}

      String.contains?(index_definition(index), cast_marker(cast)) ->
        %{index: index, action: :current}

      true ->
        Repo.query!("DROP INDEX IF EXISTS #{index}")
        create_bm25_index(index, table, column, cast)
        %{index: index, action: :rebuilt}
    end
  end

  defp ensure_hnsw_index(index, ddl) do
    cond do
      index_definition(index) == nil ->
        Repo.query!(ddl)
        %{index: index, action: :created}

      not index_usable?(index) ->
        Repo.query!("DROP INDEX IF EXISTS #{index}")
        Repo.query!(ddl)
        %{index: index, action: :rebuilt}

      true ->
        %{index: index, action: :current}
    end
  end

  defp index_definition(index) do
    %{rows: rows} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [index])

    case rows do
      [[definition]] -> definition
      [] -> nil
    end
  end

  # An index a failed build or reindex left behind is unusable even though
  # it still appears in pg_indexes.
  defp index_usable?(index) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT i.indisvalid AND i.indisready
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = $1
        """,
        [index]
      )

    case rows do
      [[usable]] -> usable == true
      [] -> false
    end
  end

  defp create_bm25_index(index, table, column, cast) do
    Repo.query!("""
    CREATE INDEX #{index}
    ON #{table}
    USING bm25 (id, (#{column}::#{cast}))
    WITH (key_field='id')
    """)
  end

  # pg_indexes normalizes lindera('japanese') casts; match on the stable
  # tokenizer name portion.
  defp cast_marker("pdb.lindera('" <> rest), do: "lindera('" <> String.trim_trailing(rest, ")")
  defp cast_marker(cast), do: cast
end
