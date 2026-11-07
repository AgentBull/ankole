defmodule Ankole.Pod.Pages.Search do
  @moduledoc """
  Full-text retrieval, ranking, snippet segmentation, and deep-link target
  resolution across Pod pages and Brain knowledge objects (`M9` retrieval).

  Candidate SQL defines caller eligibility once (`eligible_pages`), runs BM25
  index recall and lightweight title fallback without touching `body_text` or
  computing snippets before `LIMIT`, and enriches snippets and deep-link targets
  only for the winning rows. Winning pages load through
  `Ankole.Ash.read_authorized/2` so `PageAnchorFilter` projects `role` and
  `actions` identically to directory and page reads.
  """

  import Bitwise, only: [bor: 2]
  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.AuthZ.Checks.PageAnchorFilter
  alias Ankole.Pod.{Access, Page, Pages}
  alias Ankole.Pod.Pages.Search.{Query, Snippets, Targets}
  alias Ankole.Repo

  @spec search(Actor.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def search(actor, query, opts \\ %{})

  def search(%Actor{} = actor, query, opts) when is_binary(query) and is_map(opts) do
    Repo.transact_repeatable_read_only(fn ->
      search_in_tx(actor, query, opts)
    end)
  end

  def search(_actor, _query, _opts), do: {:error, :invalid_request}

  defdelegate parse_query(raw_query), to: Query
  defdelegate parse_pdb_snippet(raw_snippet, full_body), to: Snippets
  defdelegate window_highlight_segments(source_text, terms), to: Snippets

  defp search_in_tx(actor, raw_query, opts) do
    parsed = Query.parse_query(raw_query)
    tenant_id = Repo.tenant_id!()

    with {:ok, context} <- Access.context_snapshot(actor),
         {:ok, reachable} <- query_visibility(actor, opts, context),
         {:ok, filters} <- Query.normalize_filters(actor, opts, reachable, context, tenant_id) do
      policy = PageAnchorFilter.policy(reachable, filters.required_action)
      required_bits = bor(1, Access.Graph.action_bit(to_string(filters.required_action)))
      {containers, direct_pages} = Access.Graph.visibility_ids(reachable, required_bits)

      candidate_rows =
        if parsed.raw == "" do
          query_empty_candidates(actor, containers, direct_pages, filters)
        else
          rows = query_ranked_candidates(actor, parsed, containers, direct_pages, filters)
          attach_winning_snippets(rows, filters.tenant_id, parsed, filters.title_only)
        end

      ordered_ids = Enum.map(candidate_rows, & &1.page_id)

      with {:ok, loaded_pages} <-
             load_authorized_pages(actor, ordered_ids, filters.required_action, policy),
           pages = preserve_order(ordered_ids, loaded_pages),
           {:ok, ancestors} <- load_ancestors(actor, pages, policy) do
        matches =
          if parsed.raw == "" do
            []
          else
            build_matches(pages, candidate_rows, parsed, filters.title_only)
          end

        {:ok,
         %{
           pages: pages,
           matches: matches,
           ancestors: ancestors,
           principal_uid: Actor.uid(actor),
           can_create_private: Pages.Queries.can_create_private?(actor),
           can_create_space: Pages.can_create_space?(actor)
         }}
      end
    end
  end

  defp query_visibility(actor, opts, context) do
    case Map.fetch(opts, :reachable) do
      {:ok, reachable} -> {:ok, reachable}
      :error -> Access.reachable_anchors(actor, context: context)
    end
  end

  defp eligibility_params(containers, direct_pages, filters) do
    [
      filters.tenant_id,
      containers,
      direct_pages,
      filters.domain,
      filters.brain_ids,
      filters.excluded_ids,
      filters.has_subset,
      filters.subset_ids,
      filters.types,
      filters.created_by,
      filters.updated_after
    ]
  end

  defp eligible_pages_cte_sql do
    """
    eligible_pages AS (
      SELECT
        p.id,
        p.tenant_id,
        COALESCE(NULLIF(btrim(p.title), ''), p.name) AS page_title,
        p.updated_at,
        p.created_at
      FROM pages p
      WHERE p.tenant_id = $1::text::uuid
        AND p.deleted_at IS NULL
        AND NOT p.is_root
        AND ((NOT p.is_acl_anchor AND p.acl_anchor_id = ANY($2::text[]::uuid[]))
             OR (p.is_acl_anchor AND p.id = ANY($3::text[]::uuid[])))
        AND ($4::text = 'all' OR (($4::text = 'brain') = (p.id = ANY($5::text[]::uuid[]))))
        AND NOT (p.id = ANY($6::text[]::uuid[]))
        AND (NOT $7::boolean OR p.id = ANY($8::text[]::uuid[]))
        AND ($9::text[] IS NULL OR p.type::text = ANY($9::text[]))
        AND ($10::text IS NULL OR p.created_by = $10::text)
        AND ($11::timestamptz IS NULL OR p.updated_at >= $11::timestamptz)
    )
    """
  end

  defp query_empty_candidates(actor, containers, direct_pages, filters) do
    order_sql = empty_order_clause(filters.sort)

    params =
      eligibility_params(containers, direct_pages, filters) ++
        [Actor.uid(actor), filters.limit]

    Repo.query!(
      """
      WITH #{eligible_pages_cte_sql()},
      activity AS (
        SELECT page_id, SUM(views + 2 * edits)::double precision AS score
        FROM page_daily_activity
        WHERE tenant_id = $1::text::uuid AND day >= CURRENT_DATE - 30
        GROUP BY page_id
      )
      SELECT ep.id::text
      FROM eligible_pages ep
      LEFT JOIN page_user_states pus
        ON pus.tenant_id = ep.tenant_id
       AND pus.principal_uid = $12::text
       AND pus.page_id = ep.id
      LEFT JOIN activity act ON act.page_id = ep.id
      ORDER BY #{order_sql}
      LIMIT $13::integer
      """,
      params
    ).rows
    |> Enum.map(fn [page_id] ->
      %{
        page_id: page_id,
        eff_title: "",
        meta_text: "",
        body_text: "",
        title_snippet: nil,
        meta_snippet: nil,
        body_snippet: nil
      }
    end)
  end

  defp query_ranked_candidates(actor, parsed, containers, direct_pages, filters) do
    lower_raw = String.downcase(parsed.raw)
    escaped_raw = Repo.escape_like(parsed.raw)
    prefix_like = escaped_raw <> "%"
    substr_like = "%" <> escaped_raw <> "%"
    all_like_patterns = Enum.map(parsed.terms, &("%" <> Repo.escape_like(&1) <> "%"))

    base_params =
      eligibility_params(containers, direct_pages, filters) ++
        [
          Actor.uid(actor),
          filters.limit,
          lower_raw,
          prefix_like,
          substr_like,
          all_like_patterns
        ]

    {bm25_clauses_sql, dynamic_params} =
      build_bm25_predicates(parsed, filters.title_only, length(base_params) + 1)

    order_sql = ranked_order_clause(filters.sort)

    Repo.query!(
      """
      WITH #{eligible_pages_cte_sql()},
      bm25_raw AS (
        SELECT
          psd.page_id,
          pdb.score(psd.page_id)::double precision AS bm25_score
        FROM page_search_documents psd
        WHERE psd.tenant_id = $1::text::uuid
          AND #{bm25_clauses_sql}
      ),
      bm25_hits AS (
        SELECT b.page_id, b.bm25_score
        FROM bm25_raw b
        JOIN eligible_pages ep ON ep.id = b.page_id
      ),
      title_hits AS (
        SELECT
          ep.id AS page_id,
          0.0::double precision AS bm25_score
        FROM eligible_pages ep
        LEFT JOIN page_search_documents psd
          ON psd.tenant_id = ep.tenant_id AND psd.page_id = ep.id
        WHERE NOT EXISTS (SELECT 1 FROM bm25_hits b WHERE b.page_id = ep.id)
          AND (
            SELECT bool_and(COALESCE(psd.title, ep.page_title) ILIKE pat)
            FROM unnest($17::text[]) pat
          )
      ),
      candidates AS (
        SELECT page_id, bm25_score FROM bm25_hits
        UNION ALL
        SELECT page_id, bm25_score FROM title_hits
      ),
      activity AS (
        SELECT page_id, SUM(views + 2 * edits)::double precision AS score
        FROM page_daily_activity
        WHERE tenant_id = $1::text::uuid AND day >= CURRENT_DATE - 30
        GROUP BY page_id
      ),
      ranked AS (
        SELECT
          ep.id AS page_id,
          COALESCE(psd.title, ep.page_title) AS eff_title,
          ep.updated_at,
          ep.created_at,
          ((CASE
              WHEN LOWER(COALESCE(psd.title, ep.page_title)) = $14::text THEN 100.0
              WHEN COALESCE(psd.title, ep.page_title) ILIKE $15::text THEN 40.0
              WHEN COALESCE(psd.title, ep.page_title) ILIKE $16::text THEN 20.0
              ELSE 0.0
            END
            + 10.0 * ln(1.0 + GREATEST(c.bm25_score, 0.0))
            + 1.0)
           * (1.0 + 0.15 * ln(1.0 + COALESCE(act.score, 0.0)))
           * #{personal_boost_sql()}) AS final_score
        FROM candidates c
        JOIN eligible_pages ep ON ep.id = c.page_id
        LEFT JOIN page_search_documents psd
          ON psd.tenant_id = ep.tenant_id AND psd.page_id = ep.id
        LEFT JOIN page_user_states pus
          ON pus.tenant_id = ep.tenant_id
         AND pus.principal_uid = $12::text
         AND pus.page_id = ep.id
        LEFT JOIN activity act ON act.page_id = ep.id
        ORDER BY #{order_sql}
        LIMIT $13::integer
      )
      SELECT
        r.page_id::text,
        r.eff_title,
        COALESCE(psd.meta_text, '') AS meta_text,
        COALESCE(psd.body_text, '') AS body_text
      FROM ranked r
      LEFT JOIN page_search_documents psd
        ON psd.tenant_id = $1::text::uuid AND psd.page_id = r.page_id
      ORDER BY #{outer_ranked_order_clause(filters.sort)}
      """,
      base_params ++ dynamic_params
    ).rows
    |> Enum.map(fn [page_id, eff_title, meta_text, body_text] ->
      %{
        page_id: page_id,
        eff_title: eff_title || "",
        meta_text: meta_text || "",
        body_text: body_text || "",
        title_snippet: nil,
        meta_snippet: nil,
        body_snippet: nil
      }
    end)
  end

  defp attach_winning_snippets([], _tenant_id, _parsed, _title_only), do: []

  defp attach_winning_snippets(rows, tenant_id, parsed, title_only) do
    winning_ids = Enum.map(rows, & &1.page_id)
    snippets_by_id = query_winning_snippets(tenant_id, winning_ids, parsed, title_only)

    Enum.map(rows, fn row ->
      case Map.get(snippets_by_id, row.page_id) do
        {title_snip, meta_snip, body_snip} ->
          %{
            row
            | title_snippet: title_snip,
              meta_snippet: meta_snip,
              body_snippet: body_snip
          }

        nil ->
          row
      end
    end)
  end

  defp query_winning_snippets(tenant_id, winning_ids, parsed, title_only) do
    {bm25_clauses_sql, dynamic_params} = build_bm25_predicates(parsed, title_only, 3)

    title_snippet_sql = "pdb.snippet(psd.title, E'\\x1e', E'\\x1f', 120)"

    {meta_snippet_sql, body_snippet_sql} =
      if title_only do
        {"NULL::text", "NULL::text"}
      else
        {
          "pdb.snippet(psd.meta_text, E'\\x1e', E'\\x1f', 160)",
          "pdb.snippet(psd.body_text, E'\\x1e', E'\\x1f', 160)"
        }
      end

    Repo.query!(
      """
      SELECT
        psd.page_id::text,
        #{title_snippet_sql} AS title_snippet,
        #{meta_snippet_sql} AS meta_snippet,
        #{body_snippet_sql} AS body_snippet
      FROM page_search_documents psd
      WHERE psd.tenant_id = $1::text::uuid
        AND psd.page_id = ANY($2::text[]::uuid[])
        AND #{bm25_clauses_sql}
      """,
      [tenant_id, winning_ids | dynamic_params]
    ).rows
    |> Map.new(fn [page_id, title_snip, meta_snip, body_snip] ->
      {page_id, {title_snip, meta_snip, body_snip}}
    end)
  end

  defp personal_boost_sql do
    """
    (1.0
     + CASE WHEN pus.favorited_at IS NOT NULL THEN 0.25 ELSE 0.0 END
     + CASE
         WHEN GREATEST(
                CASE WHEN COALESCE(pus.hide_visits, false) THEN NULL ELSE pus.visited_at END,
                pus.edited_at
              ) IS NOT NULL
           THEN 0.35 * exp(
             -GREATEST(
               EXTRACT(EPOCH FROM (
                 CURRENT_TIMESTAMP - GREATEST(
                   CASE WHEN COALESCE(pus.hide_visits, false) THEN NULL ELSE pus.visited_at END,
                   pus.edited_at
                 )
               )) / 86400.0,
               0.0
             ) / 14.0
           )
         ELSE 0.0
       END)
    """
  end

  defp build_bm25_predicates(parsed, title_only, start_idx) do
    {phrase_clauses, rev_params_after_phrases, idx_after_phrases} =
      Enum.reduce(parsed.phrases, {[], [], start_idx}, fn phrase, {clauses, rev_params, idx} ->
        bm25 =
          if title_only do
            "psd.title @@@ pdb.phrase($#{idx}::text)"
          else
            "(psd.title @@@ pdb.phrase($#{idx}::text)::pdb.boost(4) OR psd.meta_text @@@ pdb.phrase($#{idx}::text) OR psd.body_text @@@ pdb.phrase($#{idx}::text))"
          end

        if Regex.match?(~r/[^[:alnum:]\s]/u, phrase) do
          like_idx = idx + 1
          like_pat = "%" <> Repo.escape_like(phrase) <> "%"
          guard = psd_ilike_guard(title_only, like_idx)
          {["(#{bm25} AND #{guard})" | clauses], [like_pat, phrase | rev_params], like_idx + 1}
        else
          {[bm25 | clauses], [phrase | rev_params], idx + 1}
        end
      end)

    token_count = length(parsed.tokens)

    {token_clauses, rev_final_params, _final_idx} =
      parsed.tokens
      |> Enum.with_index(1)
      |> Enum.reduce({phrase_clauses, rev_params_after_phrases, idx_after_phrases}, fn {token,
                                                                                        pos},
                                                                                       {clauses,
                                                                                        rev_params,
                                                                                        idx} ->
        last_with_prefix? = pos == token_count and parsed.prefix_token != nil

        {bm25, next_rev_params, next_idx} =
          build_token_bm25_sql(token, parsed.prefix_token, title_only, last_with_prefix?, idx)

        next_acc_params = next_rev_params ++ rev_params

        if Regex.match?(~r/[^[:alnum:]]/u, token) do
          like_pat = "%" <> Repo.escape_like(token) <> "%"
          guard = psd_ilike_guard(title_only, next_idx)
          {["(#{bm25} AND #{guard})" | clauses], [like_pat | next_acc_params], next_idx + 1}
        else
          {[bm25 | clauses], next_acc_params, next_idx}
        end
      end)

    {token_clauses |> Enum.reverse() |> Enum.join(" AND "), Enum.reverse(rev_final_params)}
  end

  defp build_token_bm25_sql(token, prefix_token, true, true, idx) do
    p_idx = idx + 1

    sql =
      "(psd.title @@@ pdb.match($#{idx}::text, conjunction_mode => true) OR psd.title @@@ pdb.phrase_prefix(ARRAY[$#{p_idx}::text]))"

    {sql, [prefix_token, token], p_idx + 1}
  end

  defp build_token_bm25_sql(token, prefix_token, false, true, idx) do
    p_idx = idx + 1

    sql =
      "(psd.title @@@ pdb.match($#{idx}::text, conjunction_mode => true)::pdb.boost(4) OR psd.meta_text @@@ pdb.match($#{idx}::text, conjunction_mode => true) OR psd.body_text @@@ pdb.match($#{idx}::text, conjunction_mode => true) OR psd.title @@@ pdb.phrase_prefix(ARRAY[$#{p_idx}::text])::pdb.boost(4) OR psd.meta_text @@@ pdb.phrase_prefix(ARRAY[$#{p_idx}::text]) OR psd.body_text @@@ pdb.phrase_prefix(ARRAY[$#{p_idx}::text]))"

    {sql, [prefix_token, token], p_idx + 1}
  end

  defp build_token_bm25_sql(token, _prefix_token, true, false, idx) do
    {"psd.title @@@ pdb.match($#{idx}::text, conjunction_mode => true)", [token], idx + 1}
  end

  defp build_token_bm25_sql(token, _prefix_token, false, false, idx) do
    sql =
      "(psd.title @@@ pdb.match($#{idx}::text, conjunction_mode => true)::pdb.boost(4) OR psd.meta_text @@@ pdb.match($#{idx}::text, conjunction_mode => true) OR psd.body_text @@@ pdb.match($#{idx}::text, conjunction_mode => true))"

    {sql, [token], idx + 1}
  end

  defp psd_ilike_guard(true, idx), do: "psd.title ILIKE $#{idx}::text"

  defp psd_ilike_guard(false, idx),
    do:
      "(psd.title ILIKE $#{idx}::text OR psd.meta_text ILIKE $#{idx}::text OR psd.body_text ILIKE $#{idx}::text)"

  defp empty_order_clause("updated_desc"), do: "ep.updated_at DESC, ep.id ASC"
  defp empty_order_clause("updated_asc"), do: "ep.updated_at ASC, ep.id ASC"
  defp empty_order_clause("created_desc"), do: "ep.created_at DESC, ep.id ASC"
  defp empty_order_clause("created_asc"), do: "ep.created_at ASC, ep.id ASC"

  defp empty_order_clause(_best) do
    """
    ((1.0 + 0.15 * ln(1.0 + COALESCE(act.score, 0.0)))
     * #{personal_boost_sql()}) DESC,
    ep.updated_at DESC,
    ep.id ASC
    """
  end

  defp ranked_order_clause("updated_desc"), do: "ep.updated_at DESC, final_score DESC, ep.id ASC"
  defp ranked_order_clause("updated_asc"), do: "ep.updated_at ASC, final_score DESC, ep.id ASC"
  defp ranked_order_clause("created_desc"), do: "ep.created_at DESC, final_score DESC, ep.id ASC"
  defp ranked_order_clause("created_asc"), do: "ep.created_at ASC, final_score DESC, ep.id ASC"
  defp ranked_order_clause(_best), do: "final_score DESC, ep.updated_at DESC, ep.id ASC"

  defp outer_ranked_order_clause("updated_desc"),
    do: "r.updated_at DESC, r.final_score DESC, r.page_id ASC"

  defp outer_ranked_order_clause("updated_asc"),
    do: "r.updated_at ASC, r.final_score DESC, r.page_id ASC"

  defp outer_ranked_order_clause("created_desc"),
    do: "r.created_at DESC, r.final_score DESC, r.page_id ASC"

  defp outer_ranked_order_clause("created_asc"),
    do: "r.created_at ASC, r.final_score DESC, r.page_id ASC"

  defp outer_ranked_order_clause(_best),
    do: "r.final_score DESC, r.updated_at DESC, r.page_id ASC"

  defp load_authorized_pages(_actor, [], _required_action, _policy), do: {:ok, []}

  defp load_authorized_pages(actor, ids, required_action, policy) do
    Page
    |> Ash.Query.for_read(:search, %{required_action: required_action})
    |> Ash.Query.filter(id in ^ids)
    |> PageAnchorFilter.apply_policy(actor, policy)
    |> Ankole.Ash.read_authorized(actor)
  end

  defp preserve_order(ids, pages) do
    by_id = Map.new(pages, &{&1.id, &1})
    Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)
  end

  defp load_ancestors(_actor, [], _policy), do: {:ok, []}

  defp load_ancestors(actor, pages, policy) do
    ids = Ankole.Pod.ancestor_node_ids(Enum.map(pages, & &1.id))

    if ids == [] do
      {:ok, []}
    else
      Page
      |> Ash.Query.filter(id in ^ids)
      |> PageAnchorFilter.apply_policy(actor, PageAnchorFilter.policy(policy.reachable))
      |> Ankole.Ash.read_authorized(actor)
    end
  end

  defp build_matches(pages, candidate_rows, parsed, title_only) do
    rows_by_id = Map.new(candidate_rows, &{&1.page_id, &1})
    lower_terms = Enum.map(parsed.terms, &String.downcase/1)

    default_cand = %{
      eff_title: "",
      meta_text: "",
      body_text: "",
      title_snippet: nil,
      meta_snippet: nil,
      body_snippet: nil
    }

    match_fields_by_id =
      Map.new(pages, fn page ->
        cand = Map.get(rows_by_id, page.id, default_cand)
        {page.id, Snippets.detect_match_fields(cand, lower_terms, title_only)}
      end)

    targets_by_id =
      Targets.resolve_targets(pages, rows_by_id, match_fields_by_id, lower_terms, title_only)

    Enum.map(pages, fn page ->
      cand = Map.get(rows_by_id, page.id, default_cand)
      match_fields = Map.get(match_fields_by_id, page.id, [:body])

      %{
        page_id: page.id,
        match_fields: match_fields,
        snippet: Snippets.build_snippet(cand, match_fields, parsed.terms, title_only),
        primary_target: Map.get(targets_by_id, page.id)
      }
    end)
  end
end
