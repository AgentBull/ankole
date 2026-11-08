defmodule Ankole.SearchIndexes do
  @moduledoc """
  Recoverable retrieval-index lifecycle across Brain and Pod: `pg_search` BM25
  indexes on `brain_chunks`, `brain_claims`, `page_search_documents`, and
  `connector_db_catalog_tables`, plus HNSW ANN indexes on `brain_chunks` and
  `brain_claims`.

  The deployment-level tokenizer comes from `brain.search_tokenizer` and maps
  through a fixed whitelist to a `pg_search` tokenizer expression; the
  configuration value never concatenates into SQL as free text. A tokenizer
  change rebuilds all BM25 indexes. Every index also rebuilds when it is
  missing or PostgreSQL marks it invalid or not ready; the base tables stay
  authoritative.
  """

  alias Ankole.Brain.Config
  alias Ankole.Repo

  # Index DDL and catalog reads act on the whole table of every tenant (M8
  # set maintenance), not on the rows of one tenant.
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site

  @bm25_indexes [
    {"brain_chunks_bm25_idx", "brain_chunks", "id", [], ["chunk_text"]},
    {"brain_claims_bm25_idx", "brain_claims", "id", [], ["claim"]},
    {"page_search_documents_bm25_idx", "page_search_documents", "page_id", ["tenant_id"],
     ["title", "meta_text", "body_text"]},
    {"connector_db_catalog_tables_bm25_idx", "connector_db_catalog_tables", "id",
     ["tenant_id", "auth_config_id"], ["search_text"]}
  ]

  # `pg_search` re-tokenizes mutable-segment rows on every search; whole Page
  # bodies make that cost unbounded, so Page writes tokenize their own row once.
  @bm25_with_options %{"page_search_documents_bm25_idx" => ", mutable_segment_rows = 0"}

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

  @maintenance_key {__MODULE__, :maintenance}

  @doc "Reads the actual shared BM25 definitions without performing index DDL."
  def configuration_status do
    cast = Map.fetch!(@tokenizer_casts, Config.search_tokenizer())

    current? =
      Enum.all?(@bm25_indexes, fn {index, _, _, _, text_columns} ->
        definition = index_definition(index)

        is_binary(definition) and
          count_occurrences(definition, cast_marker(cast)) >= length(text_columns) and
          index_usable?(index)
      end)

    if current?, do: "applied", else: :persistent_term.get(@maintenance_key, "pending_rebuild")
  rescue
    _ -> "unknown"
  end

  @doc """
  Ensures every retrieval index exists, is valid, and (for BM25) uses the
  configured tokenizer, rebuilding when a check fails. Returns the actions
  taken.
  """
  @spec ensure_current() :: {:ok, [map()]} | {:error, term()}
  def ensure_current do
    result = do_ensure_current()
    :persistent_term.erase(@maintenance_key)
    result
  rescue
    error ->
      :persistent_term.put(@maintenance_key, "failed")
      reraise error, __STACKTRACE__
  end

  defp do_ensure_current do
    case Map.fetch(@tokenizer_casts, Config.search_tokenizer()) do
      {:ok, cast} ->
        if all_indexes_current?(cast) do
          {:ok, current_actions()}
        else
          {:ok, actions} =
            Repo.transaction(
              fn ->
                Ankole.AdvisoryLock.lock!(Repo, "search-indexes:ensure_current")

                bm25_actions =
                  Enum.map(
                    @bm25_indexes,
                    fn {index, table, key_field, raw_columns, text_columns} ->
                      ensure_bm25_index(index, table, key_field, raw_columns, text_columns, cast)
                    end
                  )

                hnsw_actions =
                  Enum.map(@hnsw_indexes, fn {index, ddl} -> ensure_hnsw_index(index, ddl) end)

                bm25_actions ++ hnsw_actions
              end,
              timeout: :infinity
            )

          {:ok, actions}
        end

      :error ->
        {:error, {:unknown_search_tokenizer, Config.search_tokenizer()}}
    end
  end

  defp all_indexes_current?(cast) do
    marker = cast_marker(cast)

    Enum.all?(@bm25_indexes, fn {index, _, _, _, text_columns} ->
      definition = index_definition(index)

      is_binary(definition) and count_occurrences(definition, marker) >= length(text_columns) and
        index_usable?(index)
    end) and
      Enum.all?(@hnsw_indexes, fn {index, _ddl} ->
        is_binary(index_definition(index)) and index_usable?(index)
      end)
  end

  defp current_actions do
    Enum.map(@bm25_indexes, fn {index, _, _, _, _} -> %{index: index, action: :current} end) ++
      Enum.map(@hnsw_indexes, fn {index, _} -> %{index: index, action: :current} end)
  end

  defp ensure_bm25_index(index, table, key_field, raw_columns, text_columns, cast) do
    definition = index_definition(index)

    cond do
      definition == nil ->
        create_bm25_index(index, table, key_field, raw_columns, text_columns, cast)
        %{index: index, action: :created}

      not index_usable?(index) ->
        :persistent_term.put(@maintenance_key, "rebuilding")
        Repo.query!("DROP INDEX IF EXISTS #{index}")
        create_bm25_index(index, table, key_field, raw_columns, text_columns, cast)
        %{index: index, action: :rebuilt}

      count_occurrences(definition, cast_marker(cast)) >= length(text_columns) ->
        %{index: index, action: :current}

      true ->
        :persistent_term.put(@maintenance_key, "rebuilding")
        Repo.query!("DROP INDEX IF EXISTS #{index}")
        create_bm25_index(index, table, key_field, raw_columns, text_columns, cast)
        %{index: index, action: :rebuilt}
    end
  end

  defp ensure_hnsw_index(index, ddl) do
    cond do
      index_definition(index) == nil ->
        :persistent_term.put(@maintenance_key, "rebuilding")
        Repo.query!(ddl)
        %{index: index, action: :created}

      not index_usable?(index) ->
        :persistent_term.put(@maintenance_key, "rebuilding")
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

  defp create_bm25_index(index, table, key_field, raw_columns, text_columns, cast) do
    :persistent_term.put(@maintenance_key, "rebuilding")

    cast_exprs = Enum.map(text_columns, &"(#{&1}::#{cast})")
    columns_sql = Enum.join([key_field | raw_columns] ++ cast_exprs, ", ")

    Repo.query!("""
    CREATE INDEX #{index}
    ON #{table}
    USING bm25 (#{columns_sql})
    WITH (key_field='#{key_field}'#{Map.get(@bm25_with_options, index, "")})
    """)
  end

  # pg_indexes normalizes lindera('japanese') casts; match on the stable
  # tokenizer name portion.
  defp cast_marker("pdb.lindera('" <> rest), do: "lindera('" <> String.trim_trailing(rest, ")")
  defp cast_marker(cast), do: cast

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end
