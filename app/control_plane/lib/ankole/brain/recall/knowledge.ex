defmodule Ankole.Brain.Recall.Knowledge do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Brain.Embedding
  alias Ankole.Brain.Recall.Parallel
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Scope
  alias Ankole.Brain.TemporalDecay
  alias Ankole.Repo

  @spec search(Scope.t(), map(), map()) :: {[map()], [String.t()]}
  def search(%Scope{} = scope, request, search_config) do
    query = normalize_query(request.query)

    outcome =
      Parallel.run([
        {"knowledge entry BM25", fn -> entry_bm25(scope, request, query) end},
        {"knowledge block BM25", fn -> block_bm25(scope, request, query) end},
        {"knowledge vector", fn -> vector_search(scope, request) end}
      ])

    keyword_results =
      fuse_keyword_hits(
        Map.fetch!(outcome.results, "knowledge entry BM25"),
        Map.fetch!(outcome.results, "knowledge block BM25")
      )

    vector_results = Map.fetch!(outcome.results, "knowledge vector")

    results =
      keyword_results
      |> fuse(vector_results)
      |> hydrate_entries(request.author_kind)
      |> apply_decay(Map.fetch!(search_config, "half_life_days"))
      |> Enum.sort_by(&{-&1["score"], &1["entry_id"]})

    {results, rerank_degraded} = maybe_rerank(results, scope, request, search_config)

    {Enum.take(results, request.limit), outcome.degraded_reasons ++ rerank_degraded}
  end

  defp entry_bm25(_scope, _request, ""), do: {:ok, []}

  defp entry_bm25(scope, request, query) do
    {all_stores, stores} = stores(request.store_keys)

    sql = """
    SELECT e.id::text, pdb.score(e.id) AS score
    FROM brain_entries e
    WHERE e.owner_uid = $2
      AND ($3::boolean OR e.store_key = ANY($4::text[]))
      AND ($5::text IS NULL OR e.type = $5)
      AND ($6::text IS NULL OR EXISTS (
        SELECT 1 FROM brain_entry_blocks author_block
        WHERE author_block.entry_id = e.id
          AND author_block.author_kind = $6::brain_author_kind
      ))
      AND e.search_text @@@ $1
    ORDER BY score DESC NULLS LAST, e.updated_at DESC, e.id
    LIMIT $7
    """

    case Repo.query(sql, [
           query,
           scope.owner_uid,
           all_stores,
           stores,
           request.entry_type,
           request.author_kind,
           request.limit * 4
         ]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [entry_id, score] ->
           %{entry_id: entry_id, entry_bm25_score: score}
         end)}

      {:error, reason} ->
        {:error, {:brain_entry_bm25_failed, reason}}
    end
  end

  defp block_bm25(_scope, _request, ""), do: {:ok, []}

  defp block_bm25(scope, request, query) do
    {all_stores, stores} = stores(request.store_keys)

    sql = """
    SELECT b.entry_id::text, b.id::text, b.body, pdb.score(b.id) AS score
    FROM brain_entry_blocks b
    JOIN brain_entries e ON e.id = b.entry_id
    WHERE b.owner_uid = $2
      AND ($3::boolean OR b.store_key = ANY($4::text[]))
      AND ($5::text IS NULL OR e.type = $5)
      AND ($6::text IS NULL OR b.author_kind = $6::brain_author_kind)
      AND b.body @@@ $1
    ORDER BY score DESC NULLS LAST, b.updated_at DESC, b.id
    LIMIT $7
    """

    case Repo.query(sql, [
           query,
           scope.owner_uid,
           all_stores,
           stores,
           request.entry_type,
           request.author_kind,
           request.limit * 4
         ]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [entry_id, block_id, body, score] ->
           %{
             entry_id: entry_id,
             block_id: block_id,
             block_body: body,
             block_bm25_score: score
           }
         end)}

      {:error, reason} ->
        {:error, {:brain_block_bm25_failed, reason}}
    end
  end

  defp fuse_keyword_hits(entry_hits, block_hits) do
    entry_ranked = entry_hits |> Enum.map(& &1.entry_id) |> Enum.uniq()
    block_ranked = block_hits |> Enum.map(& &1.entry_id) |> Enum.uniq()
    raw_by_entry = merge_raw_scores(entry_hits, block_hits)

    [entry_ranked, block_ranked]
    |> Ankole.Kernel.reciprocal_rank_fusion()
    |> Enum.map(fn %{"id" => entry_id, "score" => score} ->
      raw_by_entry
      |> Map.get(entry_id, %{})
      |> Map.merge(%{
        "entry_id" => entry_id,
        "keyword_score" => score,
        "route" => "bm25"
      })
    end)
  end

  defp vector_search(scope, request) do
    with {:ok, model_uid} <- Embedding.resolve_model_agent_uid(),
         {:ok, vector, dimensions} <- Embedding.create(model_uid, request.query) do
      {all_stores, stores} = stores(request.store_keys)
      literal = Embedding.to_pgvector(vector)

      sql = """
      SELECT
        b.entry_id::text,
        b.id::text,
        b.body,
        GREATEST(e.updated_at, b.updated_at),
        1 - (b.embedding::vector(#{dimensions}) <=> ($1::text)::vector(#{dimensions})) AS score
      FROM brain_entry_blocks b
      JOIN brain_entries e ON e.id = b.entry_id
      WHERE b.owner_uid = $3
        AND ($4::boolean OR b.store_key = ANY($5::text[]))
        AND ($6::text IS NULL OR e.type = $6)
        AND ($7::text IS NULL OR b.author_kind = $7::brain_author_kind)
        AND b.embedding_state = 'synced'
        AND b.embedding_dimensions = $2
        AND b.embedding IS NOT NULL
      ORDER BY b.embedding::vector(#{dimensions}) <=> ($1::text)::vector(#{dimensions}), b.id
      LIMIT $8
      """

      case Repo.query(sql, [
             literal,
             dimensions,
             scope.owner_uid,
             all_stores,
             stores,
             request.entry_type,
             request.author_kind,
             request.limit * 4
           ]) do
        {:ok, %{rows: rows}} ->
          {:ok,
           rows
           |> Enum.map(fn [entry_id, block_id, body, updated_at, score] ->
             %{
               "entry_id" => entry_id,
               "block_id" => block_id,
               "snippet" => body,
               "updated_at" => updated_at,
               "vector_score" => score,
               "route" => "vector"
             }
           end)
           |> Enum.uniq_by(& &1["entry_id"])}

        {:error, reason} ->
          {:error, {:brain_block_vector_failed, reason}}
      end
    end
  end

  defp fuse(keyword_results, vector_results) do
    keyword_ids = Enum.map(keyword_results, & &1["entry_id"])
    vector_ids = Enum.map(vector_results, & &1["entry_id"])

    data =
      (keyword_results ++ vector_results)
      |> Enum.reduce(%{}, fn result, acc ->
        Map.update(acc, result["entry_id"], result, &merge_result(&1, result))
      end)

    [keyword_ids, vector_ids]
    |> Ankole.Kernel.reciprocal_rank_fusion()
    |> Enum.map(fn %{"id" => id, "score" => score} ->
      data
      |> Map.fetch!(id)
      |> Map.put("fused_score", score)
      |> Map.put("route", merged_route(id in keyword_ids, id in vector_ids))
    end)
  end

  defp hydrate_entries(results, author_kind) do
    ids = Enum.map(results, & &1["entry_id"])

    entries =
      Entry
      |> where([entry], entry.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    snippets = fallback_snippets(ids, author_kind)

    Enum.flat_map(results, fn result ->
      case Map.get(entries, result["entry_id"]) do
        %Entry{} = entry ->
          [
            result
            |> Map.put("layer", "knowledge")
            |> Map.put("name", entry.name)
            |> Map.put("type", entry.type)
            |> Map.put("summary", entry.summary)
            |> Map.put("aliases", entry.aliases || [])
            |> Map.put("store", entry.store_key)
            |> Map.put("lock_version", entry.lock_version)
            |> Map.put("updated_at", datetime(entry.updated_at))
            |> Map.put_new("snippet", Map.get(snippets, entry.id))
            |> Map.put("updated_at_value", entry.updated_at)
          ]

        nil ->
          []
      end
    end)
  end

  defp fallback_snippets([], _author_kind), do: %{}

  defp fallback_snippets(entry_ids, author_kind) do
    EntryBlock
    |> where([block], block.entry_id in ^entry_ids)
    |> maybe_author(author_kind)
    |> order_by([block], asc: block.entry_id, asc: block.position)
    |> Repo.all()
    |> Enum.reduce(%{}, fn block, acc -> Map.put_new(acc, block.entry_id, block.body) end)
  end

  defp apply_decay(results, half_life_days) do
    now = DateTime.utc_now(:microsecond)

    Enum.map(results, fn result ->
      updated_at = result["updated_at_value"] || now
      age_days = DateTime.diff(now, updated_at, :second) / 86_400
      multiplier = TemporalDecay.multiplier(age_days, half_life_days)

      result
      |> Map.put("decay_multiplier", multiplier)
      |> Map.put("score", result["fused_score"] * multiplier)
      |> Map.delete("updated_at_value")
    end)
  end

  defp maybe_rerank(results, _scope, _request, %{"rerank_enabled" => false}),
    do: {results, []}

  defp maybe_rerank([], _scope, _request, _config), do: {[], []}

  defp maybe_rerank(results, scope, request, config) do
    model_uid = config["rerank_model_agent_uid"] || scope.owner_uid

    documents =
      Enum.map(results, fn result ->
        [result["name"], result["type"], result["summary"], result["snippet"]]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")
      end)

    case Embedding.rerank(model_uid, request.query, documents, length(documents)) do
      {:ok, reranked} ->
        ordered =
          Enum.flat_map(reranked, fn %{"index" => index, "score" => score} ->
            case Enum.at(results, index) do
              nil -> []
              result -> [Map.put(result, "rerank_score", score)]
            end
          end)

        seen = MapSet.new(ordered, & &1["entry_id"])
        {ordered ++ Enum.reject(results, &MapSet.member?(seen, &1["entry_id"])), []}

      {:error, reason} ->
        {results, ["knowledge rerank unavailable: #{inspect(reason)}"]}
    end
  end

  defp merge_raw_scores(entry_hits, block_hits) do
    entry_scores =
      Enum.reduce(entry_hits, %{}, fn hit, acc ->
        Map.update(acc, hit.entry_id, %{"bm25_entry_score" => hit.entry_bm25_score}, fn current ->
          Map.put(
            current,
            "bm25_entry_score",
            max(current["bm25_entry_score"], hit.entry_bm25_score)
          )
        end)
      end)

    Enum.reduce(block_hits, entry_scores, fn hit, acc ->
      Map.update(
        acc,
        hit.entry_id,
        %{
          "bm25_block_score" => hit.block_bm25_score,
          "matched_block_id" => hit.block_id,
          "snippet" => hit.block_body
        },
        fn current ->
          if hit.block_bm25_score > Map.get(current, "bm25_block_score", -1.0) do
            Map.merge(current, %{
              "bm25_block_score" => hit.block_bm25_score,
              "matched_block_id" => hit.block_id,
              "snippet" => hit.block_body
            })
          else
            current
          end
        end
      )
    end)
  end

  defp merge_result(left, right) do
    Map.merge(left, right, fn
      "snippet", left_value, _right_value when is_binary(left_value) -> left_value
      _key, _left_value, right_value -> right_value
    end)
  end

  defp merged_route(true, true), do: "bm25+vector"
  defp merged_route(true, false), do: "bm25"
  defp merged_route(false, true), do: "vector"

  defp stores(:all), do: {true, []}
  defp stores(stores) when is_list(stores), do: {false, stores}

  defp maybe_author(query, nil), do: query

  defp maybe_author(query, author_kind),
    do: where(query, [block], block.author_kind == ^author_kind)

  defp normalize_query(query) do
    query
    |> String.normalize(:nfkc)
    |> String.replace(~r/[^\p{L}\p{N}_]+/u, " ")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.take(32)
    |> Enum.join(" ")
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil
end
