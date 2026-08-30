defmodule Ankole.Brain.Recall do
  @moduledoc """
  Two-arm retrieval over the knowledge space.

  The Claim arm returns structured current Facts and Takes; the Chunk arm
  returns body and timeline passages. Both arms apply the querier's
  knowledge boundary as SQL prefilters, fuse BM25 and vector candidates with
  RRF, apply graph, recency, and salience boosts, optionally rerank, then
  run the disclosure filter before assembly. One parameter set, constants in
  code: values follow GBrain balanced mode.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway
  alias Ankole.Brain.Access
  alias Ankole.Brain.Chunker
  alias Ankole.Brain.Config
  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Sanitize
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  @default_limit 25
  @default_budget_tokens 4_000
  @assembly_budget_cap 12_000
  @rrf_k 60
  @adjacency_boost 1.05
  @adjacency_min_hits 2
  @recency_halflife_days 30
  @evergreen_prefix "concepts/"
  @salience_strength 0.15
  @rerank_timeout_ms 5_000
  @max_chunks_per_page 2
  @retrieved_throttle_seconds 300
  @ln2 :math.log(2)

  @type disclosure :: Ankole.Brain.Access.disclosure()

  @doc """
  Runs one recall for a querier.

  Params: `query` (required), `entity` (optional slug or name),
  `limit` (default #{@default_limit}), `budget_tokens`
  (default #{@default_budget_tokens}).
  """
  @spec recall(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recall(querier_uid, params, opts \\ []) do
    query = String.trim(params[:query] || "")
    limit = params[:limit] || @default_limit
    budget = min(params[:budget_tokens] || @default_budget_tokens, @assembly_budget_cap)

    disclosure =
      Keyword.get(opts, :disclosure, Access.open_disclosure())

    if query == "" do
      {:error, :missing_query}
    else
      with {:ok, access} <- Access.for_readers(querier_uid, disclosure),
           {:ok, visibility} <- LazySkillVisibility.for_querier(querier_uid),
           {:ok, neighborhood} <- entity_neighborhood(params[:entity], visibility) do
        query_vector = query_embedding(query)

        claims = claim_arm(access, visibility, query, query_vector, limit, neighborhood)
        chunks = chunk_arm(access, visibility, query, query_vector, limit, neighborhood)

        claims = Access.filter_disclosable(claims, & &1.audience_scope, disclosure)
        chunks = Access.filter_disclosable(chunks, & &1.chunk.audience_scope, disclosure)

        {claim_payload, chunk_payload, sanitized_count} =
          assemble(claims, chunks, budget)

        touch_retrieved(chunk_payload, claim_payload)

        {:ok,
         %{
           claims: claim_payload,
           chunks: chunk_payload,
           sanitized_count: sanitized_count
         }}
      end
    end
  end

  # Claim arm

  defp claim_arm(access, visibility, query, query_vector, limit, neighborhood) do
    candidate_limit = min(limit * 2, 100)

    base =
      Claim
      |> Access.filter_claims(access)
      |> Access.filter_current_claims()
      |> LazySkillVisibility.filter_claims(visibility)
      |> claim_neighborhood_filter(neighborhood)

    bm25_ids =
      base
      |> where([claim], fragment("? @@@ pdb.match(?)", claim.claim, ^query))
      |> order_by([claim], desc: fragment("pdb.score(?)", claim.id))
      |> limit(^candidate_limit)
      |> select([claim], claim.id)
      |> Repo.all()

    vector_ids =
      case query_vector do
        nil -> []
        vector -> vector_candidate_ids(base, vector, candidate_limit, :claim)
      end

    {fused_ids, fused_scores} = fuse(bm25_ids, vector_ids)

    rows =
      Claim
      |> where([claim], claim.id in ^fused_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    forgetting = Config.forgetting()
    now = DateTime.utc_now()

    fused_ids
    |> Enum.map(&Map.get(rows, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn claim ->
      effective_confidence =
        case claim.claim_type do
          "fact" -> effective_confidence(claim, forgetting, now)
          "take" -> claim.weight
        end

      %{claim: claim, score: Map.fetch!(fused_scores, claim.id) * max(effective_confidence, 0.05)}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.map(fn %{claim: claim} ->
      Map.merge(
        %{audience_scope: claim.audience_scope},
        %{claim: claim}
      )
    end)
  end

  @doc """
  Effective confidence of one Fact under time decay: the stored value never
  changes, ranking multiplies `confidence * exp(-age_days / halflife)` with
  the halflife of the fact kind from `brain.forgetting`.
  """
  @spec effective_confidence(Claim.t(), map(), DateTime.t()) :: float()
  def effective_confidence(%Claim{claim_type: "fact"} = claim, forgetting, now) do
    halflife = halflife_days(claim.kind, forgetting)

    age_days =
      case claim.valid_from do
        %DateTime{} = valid_from -> max(DateTime.diff(now, valid_from, :second) / 86_400, 0.0)
        _missing -> 0.0
      end

    cond do
      claim.expired_at != nil -> 0.0
      claim.valid_until != nil and DateTime.compare(now, claim.valid_until) == :gt -> 0.0
      true -> min(max(claim.confidence * :math.exp(-age_days / halflife), 0.0), 1.0)
    end
  end

  defp halflife_days(kind, forgetting) do
    key =
      case kind do
        "event" -> "event_halflife_days"
        "preference" -> "preference_halflife_days"
        "commitment" -> "commitment_halflife_days"
        "belief" -> "belief_halflife_days"
        _fact -> "fact_halflife_days"
      end

    Map.get(forgetting, key, 365)
  end

  # Chunk arm

  defp chunk_arm(access, visibility, query, query_vector, limit, neighborhood) do
    candidate_limit = min(limit * 2, 100)

    base =
      Chunk
      |> join(:inner, [chunk], object in Object, on: object.id == chunk.object_id)
      |> where([_chunk, object], is_nil(object.deleted_at))
      |> Access.filter_chunks(access)
      |> LazySkillVisibility.filter_chunks(visibility)
      |> chunk_neighborhood_filter(neighborhood)

    bm25_ids =
      base
      |> where([chunk, _object], fragment("? @@@ pdb.match(?)", chunk.chunk_text, ^query))
      |> order_by([chunk, _object], desc: fragment("pdb.score(?)", chunk.id))
      |> limit(^candidate_limit)
      |> select([chunk, _object], chunk.id)
      |> Repo.all()

    vector_ids =
      case query_vector do
        nil -> []
        vector -> vector_candidate_ids(base, vector, candidate_limit, :chunk)
      end

    {fused_ids, fused_scores} = fuse(bm25_ids, vector_ids)

    rows =
      Chunk
      |> join(:inner, [chunk], object in Object, on: object.id == chunk.object_id)
      |> where([chunk, _object], chunk.id in ^fused_ids)
      |> select([chunk, object], {chunk, object})
      |> Repo.all()
      |> Map.new(fn {chunk, object} -> {chunk.id, {chunk, object}} end)

    hits =
      fused_ids
      |> Enum.map(&Map.get(rows, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {chunk, object} ->
        %{chunk: chunk, object: object, score: Map.fetch!(fused_scores, chunk.id)}
      end)

    hits
    |> apply_adjacency_boost(visibility)
    |> apply_recency_and_salience()
    |> maybe_rerank(query)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp vector_candidate_ids(base, {vector, signature}, candidate_limit, kind) do
    # ANN selects candidates on the first 4000 halfvec dimensions; the exact
    # order comes from the full 4096 vector over that candidate set.
    ann_limit = candidate_limit * 3

    ann_query =
      case kind do
        # The query-side parameter arrives untyped, and `subvector(unknown, ...)`
        # is ambiguous between vector and halfvec (42725), so it needs an
        # explicit `::vector` cast. The column side must stay uncast to match
        # the HNSW index expression.
        :claim ->
          base
          |> where([claim], not is_nil(claim.embedding))
          |> where([claim], claim.embedding_signature == ^signature)
          |> order_by(
            [claim],
            fragment(
              "subvector(?, 1, 4000)::halfvec(4000) <=> subvector(?::vector, 1, 4000)::halfvec(4000)",
              claim.embedding,
              ^vector
            )
          )
          |> limit(^ann_limit)
          |> select([claim], claim.id)

        :chunk ->
          base
          |> where([chunk, _object], not is_nil(chunk.embedding))
          |> where([chunk, _object], chunk.embedding_signature == ^signature)
          |> order_by(
            [chunk, _object],
            fragment(
              "subvector(?, 1, 4000)::halfvec(4000) <=> subvector(?::vector, 1, 4000)::halfvec(4000)",
              chunk.embedding,
              ^vector
            )
          )
          |> limit(^ann_limit)
          |> select([chunk, _object], chunk.id)
      end

    candidate_ids = Repo.all(ann_query)

    exact_query =
      case kind do
        :claim ->
          Claim
          |> where([claim], claim.id in ^candidate_ids)
          |> where([claim], claim.embedding_signature == ^signature)
          |> order_by([claim], fragment("? <=> ?", claim.embedding, ^vector))
          |> limit(^candidate_limit)
          |> select([claim], claim.id)

        :chunk ->
          Chunk
          |> where([chunk], chunk.id in ^candidate_ids)
          |> where([chunk], chunk.embedding_signature == ^signature)
          |> order_by([chunk], fragment("? <=> ?", chunk.embedding, ^vector))
          |> limit(^candidate_limit)
          |> select([chunk], chunk.id)
      end

    Repo.all(exact_query)
  end

  # The kernel returns each id with its real fused score: an id both routes
  # found carries the sum of both contributions, roughly twice a single-route
  # score. Rebuilding a score from the final rank here would flatten that
  # margin before the confidence and boost multipliers, so the kernel score
  # flows through. One route alone also goes through the kernel; it returns
  # the same `1 / (k + rank + 1)` scale. The inputs are cast UUIDs and a
  # constant, so a malformed-input error is a caller bug and raises.
  defp fuse(bm25_ids, vector_ids) do
    lists =
      [bm25_ids, vector_ids]
      |> Enum.reject(&(&1 == []))
      |> Enum.map(fn ids -> Enum.map(ids, &Ecto.UUID.cast!/1) end)

    case lists do
      [] ->
        {[], %{}}

      lists ->
        case NativeKernel.reciprocal_rank_fusion(lists, @rrf_k) do
          fused when is_list(fused) ->
            {Enum.map(fused, & &1["id"]), Map.new(fused, &{&1["id"], &1["score"]})}
        end
    end
  end

  # Pages adjacent (one link hop) to at least two hit pages get a small
  # graph boost.
  defp apply_adjacency_boost(hits, visibility) do
    hit_slugs = hits |> Enum.map(& &1.object.slug) |> Enum.uniq()

    if length(hit_slugs) < @adjacency_min_hits do
      hits
    else
      adjacency =
        Link
        |> where(
          [link],
          link.from_object_slug in ^hit_slugs or link.to_object_slug in ^hit_slugs
        )
        |> LazySkillVisibility.filter_links(visibility)
        |> select([link], {link.from_object_slug, link.to_object_slug})
        |> Repo.all()
        |> Enum.flat_map(fn {from, to} ->
          [{from, to}, {to, from}]
        end)
        |> Enum.filter(fn {hit, _neighbor} -> hit in hit_slugs end)
        |> Enum.group_by(fn {_hit, neighbor} -> neighbor end, fn {hit, _neighbor} -> hit end)
        |> Map.new(fn {neighbor, hit_neighbors} ->
          {neighbor, hit_neighbors |> Enum.uniq() |> length()}
        end)

      Enum.map(hits, fn hit ->
        if Map.get(adjacency, hit.object.slug, 0) >= @adjacency_min_hits,
          do: %{hit | score: hit.score * @adjacency_boost},
          else: hit
      end)
    end
  end

  defp apply_recency_and_salience(hits) do
    slugs = hits |> Enum.map(& &1.object.slug) |> Enum.uniq()

    take_counts =
      Claim
      |> where([claim], claim.claim_type == "take" and claim.active == true)
      |> where([claim], claim.object_slug in ^slugs)
      |> group_by([claim], claim.object_slug)
      |> select([claim], {claim.object_slug, count(claim.id)})
      |> Repo.all()
      |> Map.new()

    today = Date.utc_today()

    Enum.map(hits, fn hit ->
      recency = recency_factor(hit.object, today)
      salience = salience_factor(hit.object, Map.get(take_counts, hit.object.slug, 0))
      %{hit | score: hit.score * recency * salience}
    end)
  end

  defp recency_factor(%Object{slug: @evergreen_prefix <> _rest}, _today), do: 1.0

  defp recency_factor(%Object{} = object, today) do
    date = object.effective_date || DateTime.to_date(object.updated_at)
    age_days = max(Date.diff(today, date), 0)
    1.0 + 0.5 * :math.exp(-@ln2 * age_days / @recency_halflife_days)
  end

  defp salience_factor(%Object{emotional_weight: weight}, take_count) do
    raw = weight * 5 + :math.log(1 + take_count)
    1.0 + @salience_strength * :math.log(1 + raw)
  end

  # Cross-encoder rerank over the fused candidates when a rerank model is
  # configured; a timeout or failure keeps the fusion order (fail open).
  defp maybe_rerank(hits, query) do
    case Config.rerank_model() do
      nil ->
        hits

      model ->
        documents = Enum.map(hits, & &1.chunk.chunk_text)

        # The task is linked, so an exception inside the gateway call must
        # not escape it: fail open means a raise degrades to the fusion
        # order exactly like a timeout does.
        task =
          Task.async(fn ->
            try do
              AIGateway.create_rerank(Embeddings.subject_uid(), %{
                "model" => model["provider_id"] <> "/" <> model["model"],
                "query" => query,
                "documents" => documents,
                "top_n" => length(documents)
              })
            rescue
              error -> {:error, error}
            catch
              :exit, reason -> {:error, reason}
            end
          end)

        case Task.yield(task, @rerank_timeout_ms) || Task.shutdown(task) do
          {:ok, {:ok, %{body: %{"results" => results}}}} when is_list(results) ->
            scores =
              Map.new(results, fn result ->
                {result["index"], result["relevance_score"] || 0.0}
              end)

            hits
            |> Enum.with_index()
            |> Enum.map(fn {hit, index} ->
              %{hit | score: Map.get(scores, index, 0.0)}
            end)

          _timeout_or_failure ->
            hits
        end
    end
  end

  # Assembly

  # Claims take the budget first; chunks fill the remainder with at most two
  # chunks per page.
  defp assemble(claims, chunks, budget) do
    {claim_payload, used_tokens, sanitized_claims} =
      Enum.reduce_while(claims, {[], 0, 0}, fn %{claim: claim}, {acc, used, sanitized} ->
        {text, matched} = Sanitize.sanitize(claim.claim)
        tokens = Chunker.estimate_tokens(text)

        if used + tokens > budget do
          {:halt, {acc, used, sanitized}}
        else
          payload = %{
            id: claim.id,
            claim_type: claim.claim_type,
            claim: text,
            kind: claim.kind,
            holder: claim.holder,
            confidence: claim.confidence,
            weight: claim.weight,
            notability: claim.notability,
            valid_from: claim.valid_from,
            valid_until: claim.valid_until,
            since_date: claim.since_date,
            until_date: claim.until_date,
            object_slug: claim.object_slug,
            signal_gateway_channel_id: claim.signal_gateway_channel_id,
            provenance: claim.provenance,
            audience_scope: claim.audience_scope
          }

          {:cont, {[payload | acc], used + tokens, sanitized + sanitized_count(matched)}}
        end
      end)

    {chunk_payload, _used, sanitized_chunks, _per_page} =
      Enum.reduce_while(chunks, {[], used_tokens, 0, %{}}, fn hit,
                                                              {acc, used, sanitized, per_page} ->
        slug = hit.object.slug

        if Map.get(per_page, slug, 0) >= @max_chunks_per_page do
          {:cont, {acc, used, sanitized, per_page}}
        else
          {text, matched} = Sanitize.sanitize(hit.chunk.chunk_text)
          tokens = Chunker.estimate_tokens(text)

          if used + tokens > budget do
            {:halt, {acc, used, sanitized, per_page}}
          else
            payload = %{
              object_slug: slug,
              title: hit.object.title,
              type: hit.object.type,
              chunk_index: hit.chunk.chunk_index,
              content_kind: hit.chunk.content_kind,
              text: text,
              audience_scope: hit.chunk.audience_scope
            }

            {:cont,
             {[payload | acc], used + tokens, sanitized + sanitized_count(matched),
              Map.update(per_page, slug, 1, &(&1 + 1))}}
          end
        end
      end)

    {Enum.reverse(claim_payload), Enum.reverse(chunk_payload),
     sanitized_claims + sanitized_chunks}
  end

  defp sanitized_count([]), do: 0
  defp sanitized_count(_matched), do: 1

  # Retrieved pages remember the hit for freshness maintenance; a five-minute
  # throttle keeps hot pages from writing on every recall.
  defp touch_retrieved(chunk_payload, claim_payload) do
    slugs =
      (Enum.map(chunk_payload, & &1.object_slug) ++
         Enum.map(claim_payload, & &1.object_slug))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if slugs != [] do
      threshold = DateTime.add(DateTime.utc_now(), -@retrieved_throttle_seconds, :second)

      Object
      |> where([object], object.slug in ^slugs)
      |> where(
        [object],
        is_nil(object.last_retrieved_at) or object.last_retrieved_at < ^threshold
      )
      |> Repo.update_all(set: [last_retrieved_at: DateTime.utc_now(:microsecond)])
    end

    :ok
  end

  # Entity narrowing and query embedding

  # Resolving an entity narrows both arms to the entity's parent container
  # and one-hop link neighborhood. An entity that does not resolve is an
  # explicit error, never a silent global query.
  defp entity_neighborhood(nil, _visibility), do: {:ok, nil}
  defp entity_neighborhood("", _visibility), do: {:ok, nil}

  defp entity_neighborhood(entity, visibility) when is_binary(entity) do
    case Ankole.Brain.Objects.resolve_reference(entity, lazy_skill_visibility: visibility) do
      {:ok, object} ->
        neighbors =
          Link
          |> where(
            [link],
            link.from_object_slug == ^object.slug or link.to_object_slug == ^object.slug
          )
          |> LazySkillVisibility.filter_links(visibility)
          |> select([link], {link.from_object_slug, link.to_object_slug})
          |> Repo.all()
          |> Enum.flat_map(fn {from, to} -> [from, to] end)

        {:ok, Enum.uniq([object.slug | neighbors])}

      {:ambiguous, candidates} ->
        {:error, {:ambiguous_entity, candidates}}

      {:error, :not_found} ->
        {:error, {:entity_not_found, entity}}
    end
  end

  defp claim_neighborhood_filter(query, nil), do: query

  defp claim_neighborhood_filter(query, slugs),
    do: where(query, [claim], claim.object_slug in ^slugs)

  defp chunk_neighborhood_filter(query, nil), do: query

  defp chunk_neighborhood_filter(query, slugs),
    do: where(query, [_chunk, object], object.slug in ^slugs)

  defp query_embedding(query) do
    case Embeddings.embed_texts([query]) do
      {:ok, {[vector], signature}} -> {vector, signature}
      {:error, _reason} -> nil
    end
  end
end
