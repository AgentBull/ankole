defmodule Ankole.Brain.Recall.Knowledge do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @spec keyword_candidates(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def keyword_candidates(%Scope{} = scope, request) do
    query = normalize_query(request.query)

    if query == "" do
      {:ok, []}
    else
      with {:ok, entry_hits} <- entry_bm25(scope, request, query),
           {:ok, block_hits} <- block_bm25(scope, request, query) do
        entry_hits
        |> fuse_keyword_hits(block_hits)
        |> hydrate_candidates()
        |> then(&{:ok, &1})
      end
    end
  end

  @spec vector_candidates(Scope.t(), map(), {Pgvector.t(), pos_integer(), String.t()}) ::
          {:ok, [map()]} | {:error, term()}
  def vector_candidates(%Scope{} = scope, request, {vector, dimensions, model_agent_uid}) do
    {all_private, private_stores, shared?} = store_filter(request.store_keys)
    shared_owner_uid = Scope.shared_owner_uid()

    sql = """
    WITH nearest AS MATERIALIZED (
      SELECT
        b.entry_id::text AS entry_id,
        b.id::text AS block_id,
        b.body,
        GREATEST(e.updated_at, b.updated_at) AS occurred_at,
        b.embedding
      FROM brain_entry_blocks b
      JOIN brain_entries e ON e.id = b.entry_id
      WHERE (
          (b.owner_uid = $4 AND ($5::boolean OR b.store_key = ANY($6::text[]))) OR
          ($7::boolean AND b.owner_uid = $8 AND b.store_key = 'shared')
        )
        AND ($9::text IS NULL OR e.type = $9)
        AND ($10::text IS NULL OR b.author_kind = $10::brain_author_kind)
        AND b.embedding_state = 'synced'
        AND b.embedding_dimensions = $2
        AND b.embedding_model_agent_uid = $3
        AND b.embedding IS NOT NULL
      ORDER BY
        (subvector(b.embedding, 1, 4000)::halfvec(4000)) <=>
          (subvector($1::vector, 1, 4000)::halfvec(4000)),
        b.id
      LIMIT $11
    )
    SELECT entry_id, block_id, body, occurred_at,
           1 - (embedding <=> $1) AS score
    FROM nearest
    ORDER BY embedding <=> $1, block_id
    LIMIT $12
    """

    case Repo.query(sql, [
           vector,
           dimensions,
           model_agent_uid,
           scope.owner_uid,
           all_private,
           private_stores,
           shared?,
           shared_owner_uid,
           request.entry_type,
           request.author_kind,
           request.limit * 32,
           request.limit * 8
         ]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [entry_id, block_id, body, updated_at, score] ->
          %{
            "candidate_id" => "knowledge:entry:#{entry_id}",
            "layer" => "knowledge",
            "kind" => "knowledge_entry",
            "entry_id" => entry_id,
            "matched_block_id" => block_id,
            "matched_text" => body,
            "vector_score" => score,
            "occurred_at_value" => updated_at
          }
        end)
        |> Enum.uniq_by(& &1["candidate_id"])
        |> hydrate_candidates()
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, {:brain_block_vector_failed, reason}}
    end
  end

  @spec expand(map(), map(), pos_integer()) :: map() | nil
  def expand(candidate, request, token_cap) do
    with %Entry{} = entry <- Repo.get(Entry, candidate["entry_id"]) do
      blocks =
        EntryBlock
        |> where([block], block.entry_id == ^entry.id)
        |> maybe_author(request.author_kind)
        |> order_by([block], asc: block.position, asc: block.id)
        |> Repo.all()

      body =
        blocks
        |> Enum.map(fn block ->
          "[block #{block.position}] #{block.author_kind}\n#{block.body}"
        end)
        |> Enum.join("\n\n")
        |> cap_text(token_cap)

      candidate
      |> Map.put("name", entry.name)
      |> Map.put("type", entry.type)
      |> Map.put("summary", entry.summary)
      |> Map.put("aliases", entry.aliases || [])
      |> Map.put("properties", entry.properties || %{})
      |> Map.put("store", entry.store_key)
      |> Map.put("lock_version", entry.lock_version)
      |> Map.put("updated_at", datetime(entry.updated_at))
      |> Map.put("snippet", body)
    end
  end

  @spec rerank_text(map()) :: String.t()
  def rerank_text(candidate) do
    [
      candidate["name"],
      candidate["type"],
      candidate["summary"],
      candidate["matched_text"]
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp entry_bm25(scope, request, query) do
    {all_private, private_stores, shared?} = store_filter(request.store_keys)
    shared_owner_uid = Scope.shared_owner_uid()

    sql = """
    SELECT e.id::text, e.updated_at, pdb.score(e.id) AS score
    FROM brain_entries e
    WHERE (
        (e.owner_uid = $2 AND ($3::boolean OR e.store_key = ANY($4::text[]))) OR
        ($5::boolean AND e.owner_uid = $6 AND e.store_key = 'shared')
      )
      AND ($7::text IS NULL OR e.type = $7)
      AND ($8::text IS NULL OR EXISTS (
        SELECT 1 FROM brain_entry_blocks author_block
        WHERE author_block.entry_id = e.id
          AND author_block.author_kind = $8::brain_author_kind
      ))
      AND e.search_text @@@ $1
    ORDER BY score DESC NULLS LAST, e.updated_at DESC, e.id
    LIMIT $9
    """

    case Repo.query(sql, [
           query,
           scope.owner_uid,
           all_private,
           private_stores,
           shared?,
           shared_owner_uid,
           request.entry_type,
           request.author_kind,
           request.limit * 8
         ]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [entry_id, updated_at, score] ->
           %{entry_id: entry_id, updated_at: updated_at, score: score}
         end)}

      {:error, reason} ->
        {:error, {:brain_entry_bm25_failed, reason}}
    end
  end

  defp block_bm25(scope, request, query) do
    {all_private, private_stores, shared?} = store_filter(request.store_keys)
    shared_owner_uid = Scope.shared_owner_uid()

    sql = """
    SELECT b.entry_id::text, b.id::text, b.body, GREATEST(e.updated_at, b.updated_at),
           pdb.score(b.id) AS score
    FROM brain_entry_blocks b
    JOIN brain_entries e ON e.id = b.entry_id
    WHERE (
        (b.owner_uid = $2 AND ($3::boolean OR b.store_key = ANY($4::text[]))) OR
        ($5::boolean AND b.owner_uid = $6 AND b.store_key = 'shared')
      )
      AND ($7::text IS NULL OR e.type = $7)
      AND ($8::text IS NULL OR b.author_kind = $8::brain_author_kind)
      AND b.body @@@ $1
    ORDER BY score DESC NULLS LAST, b.updated_at DESC, b.id
    LIMIT $9
    """

    case Repo.query(sql, [
           query,
           scope.owner_uid,
           all_private,
           private_stores,
           shared?,
           shared_owner_uid,
           request.entry_type,
           request.author_kind,
           request.limit * 8
         ]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [entry_id, block_id, body, updated_at, score] ->
           %{
             entry_id: entry_id,
             block_id: block_id,
             body: body,
             updated_at: updated_at,
             score: score
           }
         end)}

      {:error, reason} ->
        {:error, {:brain_block_bm25_failed, reason}}
    end
  end

  defp fuse_keyword_hits(entry_hits, block_hits) do
    entry_ids = entry_hits |> Enum.map(& &1.entry_id) |> Enum.uniq()
    block_ids = block_hits |> Enum.map(& &1.entry_id) |> Enum.uniq()

    data =
      Enum.reduce(entry_hits, %{}, fn hit, acc ->
        Map.put_new(acc, hit.entry_id, %{
          "entry_id" => hit.entry_id,
          "occurred_at_value" => hit.updated_at,
          "bm25_entry_score" => hit.score
        })
      end)

    data =
      Enum.reduce(block_hits, data, fn hit, acc ->
        Map.update(
          acc,
          hit.entry_id,
          %{
            "entry_id" => hit.entry_id,
            "occurred_at_value" => hit.updated_at,
            "matched_block_id" => hit.block_id,
            "matched_text" => hit.body,
            "bm25_block_score" => hit.score
          },
          fn current ->
            current
            |> Map.put_new("matched_block_id", hit.block_id)
            |> Map.put_new("matched_text", hit.body)
            |> Map.put_new("bm25_block_score", hit.score)
            |> Map.update("occurred_at_value", hit.updated_at, &latest(&1, hit.updated_at))
          end
        )
      end)

    [entry_ids, block_ids]
    |> Ankole.Kernel.reciprocal_rank_fusion()
    |> Enum.map(fn %{"id" => entry_id, "score" => score} ->
      data
      |> Map.fetch!(entry_id)
      |> Map.merge(%{
        "candidate_id" => "knowledge:entry:#{entry_id}",
        "layer" => "knowledge",
        "kind" => "knowledge_entry",
        "keyword_score" => score
      })
    end)
  end

  defp hydrate_candidates([]), do: []

  defp hydrate_candidates(candidates) do
    ids = Enum.map(candidates, & &1["entry_id"])

    entries =
      Entry
      |> where([entry], entry.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(candidates, fn candidate ->
      case Map.get(entries, candidate["entry_id"]) do
        %Entry{} = entry ->
          [
            candidate
            |> Map.put("name", entry.name)
            |> Map.put("type", entry.type)
            |> Map.put("summary", entry.summary)
            |> Map.put("store", entry.store_key)
            |> Map.put_new("occurred_at_value", entry.updated_at)
          ]

        nil ->
          []
      end
    end)
  end

  defp store_filter(:all), do: {true, [], true}

  defp store_filter(stores) when is_list(stores) do
    {false, Enum.reject(stores, &(&1 == "shared")), "shared" in stores}
  end

  defp maybe_author(query, nil), do: query
  defp maybe_author(query, kind), do: where(query, [block], block.author_kind == ^kind)

  defp cap_text(text, cap) when is_binary(text) and is_integer(cap) and cap > 0 do
    if Ankole.Kernel.estimate_o200k_base_tokens(text) <= cap do
      text
    else
      graphemes = String.graphemes(text)

      0..length(graphemes)
      |> Enum.reduce_while({0, length(graphemes), ""}, fn _, {low, high, best} ->
        if low > high do
          {:halt, {low, high, best}}
        else
          middle = div(low + high, 2)
          candidate = graphemes |> Enum.take(middle) |> Enum.join()

          if Ankole.Kernel.estimate_o200k_base_tokens(candidate) <= cap do
            {:cont, {middle + 1, high, candidate}}
          else
            {:cont, {low, middle - 1, best}}
          end
        end
      end)
      |> elem(2)
    end
  end

  defp latest(nil, right), do: right
  defp latest(left, nil), do: left

  defp latest(left, right) do
    if temporal_key(left) < temporal_key(right), do: right, else: left
  end

  defp temporal_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp temporal_key(%NaiveDateTime{} = value),
    do: NaiveDateTime.diff(value, ~N[1970-01-01 00:00:00], :microsecond)

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
