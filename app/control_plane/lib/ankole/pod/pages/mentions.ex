defmodule Ankole.Pod.Pages.Mentions do
  @moduledoc """
  Owns inline `@` mention candidate search and permission-gated metadata resolution
  across Pod Pages and tenant Principals.
  """
  import Bitwise
  require Ash.Expr
  require Ash.Query
  alias Ankole.{AuthZ, Repo}
  alias Ankole.Files.Access
  alias Ankole.Pod.{Files, Page, PageContent, Pages, PageUserState}
  alias Ankole.Pod.Pages.Collaborators

  @max_candidates_limit 30
  @default_candidates_limit 20
  @max_resolve_ids 200
  @page_mention_regex ~r/<mention\s+page="([^"]+)"\s*\/>/
  @principal_mention_regex ~r/<mention\s+principal="([^"]+)"\s*\/>/

  def candidates(%AuthZ.Actor{} = actor, opts \\ %{}) when is_map(opts) do
    Repo.transact_repeatable_read_only(fn -> candidates_in_tx(actor, opts) end)
  end

  @doc false
  def candidates_in_tx(%AuthZ.Actor{} = actor, opts) do
    with {:ok, _} <- Access.principal(actor),
         {:ok, category} <- normalize_category(Ankole.Attrs.get(opts, :category, :all)),
         {:ok, current_page_id} <-
           normalize_optional_uuid(Ankole.Attrs.get(opts, :current_page_id)),
         {:ok, limit} <-
           normalize_limit(Ankole.Attrs.get(opts, :limit, @default_candidates_limit)),
         {:ok, reachable} <- Access.reachable_anchors(actor),
         {:ok, visible_uids} <-
           Collaborators.visible_principal_uids_in_tx(actor, reachable,
             context_page_id: current_page_id
           ) do
      term =
        opts
        |> Ankole.Attrs.get(:query, "")
        |> Kernel.||("")
        |> to_string()
        |> String.trim()

      {ranked_pages, page_total} =
        search_page_candidates(actor, term, current_page_id, reachable, limit)

      {ranked_principals, principal_total} =
        search_principal_candidates(
          actor,
          term,
          current_page_id,
          reachable,
          visible_uids,
          limit
        )

      {pages, principals, ranking} =
        select_category_results(category, ranked_pages, ranked_principals, limit)

      {:ok,
       %{
         space_name: Collaborators.current_space_name(),
         total_all_matches: page_total + principal_total,
         pages: pages,
         principals: principals,
         ranking: ranking
       }}
    end
  end

  def resolve(%AuthZ.Actor{} = actor, attrs) when is_map(attrs) do
    Repo.transact_repeatable_read_only(fn -> resolve_in_tx(actor, attrs) end)
  end

  def resolve(_actor, _attrs), do: {:error, :invalid_request}

  @doc false
  def resolve_in_tx(%AuthZ.Actor{} = actor, attrs) do
    with {:ok, context} <- Access.context_snapshot(actor),
         {:ok, page_ids} <- normalize_id_list(Ankole.Attrs.get(attrs, :page_ids, [])),
         {:ok, principal_uids} <-
           normalize_id_list(Ankole.Attrs.get(attrs, :principal_uids, [])),
         {:ok, context_page_id} <-
           normalize_optional_uuid(Ankole.Attrs.get(attrs, :context_page_id)),
         {:ok, reachable} <- Access.reachable_anchors(actor, context: context),
         {:ok, visible_uids} <-
           Collaborators.visible_principal_uids_in_tx(actor, reachable,
             context_page_id: context_page_id
           ) do
      {:ok,
       %{
         space_name: Collaborators.current_space_name(),
         pages: resolve_pages(actor, page_ids, reachable, context),
         principals:
           resolve_principals(
             principal_uids,
             visible_uids,
             readable_mentions(visible_uids, context_page_id, reachable)
           )
       }}
    end
  end

  @doc """
  Extracts `<mention />` references from canonical XML and resolves them under `actor`'s
  visibility boundary for Agent RPC `pages.read` responses.
  """
  def resolve_xml_references(%AuthZ.Actor{} = actor, xml, context_page_id \\ nil)
      when is_binary(xml) do
    page_ids =
      @page_mention_regex
      |> Regex.scan(xml, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.take(@max_resolve_ids)

    principal_uids =
      @principal_mention_regex
      |> Regex.scan(xml, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.take(@max_resolve_ids)

    if page_ids == [] and principal_uids == [] do
      %{pages: [], principals: []}
    else
      case resolve(actor, %{
             page_ids: page_ids,
             principal_uids: principal_uids,
             context_page_id: context_page_id
           }) do
        {:ok, result} -> %{pages: result.pages, principals: result.principals}
        _ -> %{pages: [], principals: []}
      end
    end
  end

  # --- Category Selection & First-Screen Grouping ---

  defp select_category_results(:page, ranked_pages, _ranked_principals, limit) do
    pages = Enum.take(ranked_pages, limit)
    ranking = Enum.map(pages, &%{kind: :page, id: &1.id})
    {pages, [], ranking}
  end

  defp select_category_results(:principal, _ranked_pages, ranked_principals, limit) do
    principals = Enum.take(ranked_principals, limit)
    ranking = Enum.map(principals, &%{kind: :principal, id: &1.principal_uid})
    {[], principals, ranking}
  end

  defp select_category_results(:all, ranked_pages, ranked_principals, limit) do
    all_cap = min(limit, 6)
    half = div(all_cap, 2)
    base_pages = min(length(ranked_pages), half)
    base_principals = min(length(ranked_principals), half)
    spare = all_cap - base_pages - base_principals
    extra_pages = min(max(0, length(ranked_pages) - base_pages), spare)

    extra_principals =
      min(max(0, length(ranked_principals) - base_principals), spare - extra_pages)

    pages = Enum.take(ranked_pages, base_pages + extra_pages)
    principals = Enum.take(ranked_principals, base_principals + extra_principals)

    ranking =
      Enum.map(pages, &%{kind: :page, id: &1.id}) ++
        Enum.map(principals, &%{kind: :principal, id: &1.principal_uid})

    {pages, principals, ranking}
  end

  # --- Page Candidates ---

  defp search_page_candidates(actor, "", current_page_id, reachable, limit) do
    uid = AuthZ.Actor.uid(actor)
    base = visible_pages_query(reachable) |> maybe_exclude_page(current_page_id)
    total = Ankole.Ash.count!(base)

    state_ids =
      PageUserState
      |> Ash.Query.filter(
        principal_uid == ^uid and (not is_nil(visited_at) or not is_nil(edited_at))
      )
      |> Ash.Query.calculate(
        :last_touched_at,
        :utc_datetime_usec,
        Ash.Expr.expr(fragment("GREATEST(?, ?)", visited_at, edited_at))
      )
      |> then(fn built ->
        Ash.Query.sort(built, [{built.calculations.last_touched_at, :desc}, {:page_id, :asc}])
      end)
      |> Ash.Query.select([:page_id])
      |> Ash.Query.limit(200)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.page_id)
      |> Enum.reject(&(&1 == current_page_id))

    mru_pages = fetch_visible_pages_in_order(base, state_ids, limit)
    mru_ids = Enum.map(mru_pages, & &1.id)
    remaining = max(0, limit - length(mru_pages))

    backfill_pages =
      if remaining > 0 do
        base
        |> maybe_exclude_ids(mru_ids)
        |> Ash.Query.sort(updated_at: :desc, id: :asc)
        |> Ash.Query.limit(remaining)
        |> Ankole.Ash.read!()
      else
        []
      end

    pages = mru_pages ++ backfill_pages
    ancestor_map = load_ancestor_map(pages)

    {Enum.map(pages, &page_candidate_json(&1, ancestor_map, reachable)), total}
  end

  defp search_page_candidates(_actor, term, current_page_id, reachable, limit) do
    escaped = Repo.escape_like(term)
    contains_pattern = "%" <> escaped <> "%"
    prefix_pattern = escaped <> "%"
    lower_term = String.downcase(term)

    matched_base =
      visible_pages_query(reachable)
      |> Ash.Query.filter(ilike(title, ^contains_pattern))

    total = Ankole.Ash.count!(matched_base)

    pages =
      matched_base
      |> Ash.Query.calculate(
        :tier,
        :integer,
        page_tier_expr(current_page_id, lower_term, prefix_pattern)
      )
      |> Ash.Query.calculate(
        :sim,
        :float,
        Ash.Expr.expr(fragment("similarity(?, ?::text)", title, ^term))
      )
      |> then(fn built ->
        Ash.Query.sort(built, [
          {built.calculations.tier, :desc},
          {built.calculations.sim, :desc},
          {:updated_at, :desc},
          {:id, :asc}
        ])
      end)
      |> Ash.Query.limit(limit)
      |> Ankole.Ash.read!()

    ancestor_map = load_ancestor_map(pages)

    {Enum.map(pages, &page_candidate_json(&1, ancestor_map, reachable)), total}
  end

  defp fetch_visible_pages_in_order(_base, [], _limit), do: []

  defp fetch_visible_pages_in_order(base, ordered_ids, limit) do
    by_id =
      base
      |> Ash.Query.filter(id in ^ordered_ids)
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.id, &1})

    ordered_ids
    |> Enum.flat_map(fn id ->
      case Map.get(by_id, id) do
        nil -> []
        page -> [page]
      end
    end)
    |> Enum.take(limit)
  end

  defp visible_pages_query(reachable) do
    ids = Ankole.Files.visible_node_ids(reachable)

    Page
    |> Ash.Query.filter(id in ^ids and not is_root)
  end

  defp maybe_exclude_page(query, nil), do: query
  defp maybe_exclude_page(query, page_id), do: Ash.Query.filter(query, id != ^page_id)

  defp maybe_exclude_ids(query, []), do: query
  defp maybe_exclude_ids(query, ids), do: Ash.Query.filter(query, id not in ^ids)

  defp page_tier_expr(nil, lower_term, prefix_pattern) do
    Ash.Expr.expr(
      cond do
        fragment("lower(?)", title) == ^lower_term -> 4
        ilike(title, ^prefix_pattern) -> 3
        true -> 2
      end
    )
  end

  defp page_tier_expr(current_page_id, lower_term, prefix_pattern) do
    Ash.Expr.expr(
      cond do
        id == ^current_page_id -> 0
        fragment("lower(?)", title) == ^lower_term -> 4
        ilike(title, ^prefix_pattern) -> 3
        true -> 2
      end
    )
  end

  defp page_candidate_json(page, ancestor_map, reachable) do
    %{
      id: page.id,
      type: page.type,
      title: page.title,
      icon: page.icon,
      private_owner_uid: page.private_owner_uid,
      ancestors: readable_ancestor_titles(page, ancestor_map, reachable),
      updated_at: page.updated_at
    }
  end

  # --- Principal Candidates ---

  defp search_principal_candidates(
         actor,
         term,
         current_page_id,
         reachable,
         visible_uids,
         limit
       ) do
    is_guest? = visible_uids != :all

    if is_guest? and MapSet.size(visible_uids) == 0 do
      {[], 0}
    else
      actor_uid = AuthZ.Actor.uid(actor)
      priority_uids = context_collaborator_uids(current_page_id, reachable)

      assistant =
        Ankole.Principals.personal_assistant(
          Ankole.Principals.authority_uid(AuthZ.Actor.uid(actor))
        )

      principals =
        Ankole.Principals.list_principals!(
          query: [
            filter: principal_search_filter(term, visible_uids, assistant),
            load: [:human_user, :agent],
            sort: [uid: :asc]
          ]
        )
        |> Enum.filter(&(principal_visible?(&1, visible_uids) and mentionable_principal?(&1)))

      if term == "" do
        sorted =
          principals
          |> Enum.sort_by(fn principal ->
            name_down = String.downcase(principal_display_name(principal))
            in_page = if MapSet.member?(priority_uids, principal.uid), do: 0, else: 1
            self_rank = if principal.uid == actor_uid, do: 1, else: 0
            kind_rank = if principal.type == :human, do: 0, else: 1
            {in_page, self_rank, kind_rank, name_down, principal.uid}
          end)

        entries =
          sorted
          |> Enum.take(limit)
          |> Enum.map(&principal_candidate_json(&1, is_guest?))

        {entries, length(principals)}
      else
        needle = String.downcase(term)
        uid_needle = String.trim_leading(needle, "@")

        matched =
          principals
          |> Enum.flat_map(fn principal ->
            score =
              if assistant && principal.uid == assistant.uid &&
                   assistant_alias_match?(assistant, term),
                 do: {4, 1.0, 1.0},
                 else:
                   score_principal_match(principal, needle, uid_needle, priority_uids, is_guest?)

            case score do
              nil ->
                []

              {tier, similarity, boost} ->
                [
                  {tier, similarity, boost, String.downcase(principal_display_name(principal)),
                   principal}
                ]
            end
          end)
          |> Enum.sort_by(fn {tier, similarity, boost, name_down, principal} ->
            {-tier, -similarity, -boost, name_down, principal.uid}
          end)

        entries =
          matched
          |> Enum.take(limit)
          |> Enum.map(fn {_, _, _, _, principal} ->
            principal_candidate_json(principal, is_guest?)
          end)

        {entries, length(matched)}
      end
    end
  end

  defp principal_search_filter(term, visible_uids, assistant) do
    assistant_uid = if assistant, do: assistant.uid

    base_expr =
      case visible_uids do
        :all ->
          Ash.Expr.expr(status == :active and type in [:human, :agent])

        %MapSet{} ->
          visible_list = MapSet.to_list(visible_uids)
          Ash.Expr.expr(status == :active and type in [:human, :agent] and uid in ^visible_list)
      end

    kinds = Ash.Expr.expr(type == :human or agent.type == :ai_colleague)
    kinds = if assistant, do: Ash.Expr.expr(^kinds or uid == ^assistant_uid), else: kinds
    base_expr = Ash.Expr.expr(^base_expr and ^kinds)

    if term == "" do
      base_expr
    else
      contains_pattern = "%" <> Repo.escape_like(term) <> "%"
      uid_term = String.trim_leading(term, "@")
      uid_pattern = "%" <> Repo.escape_like(uid_term) <> "%"

      match_expr =
        principal_term_expr(visible_uids != :all, contains_pattern, uid_term, uid_pattern)

      if assistant_alias_match?(assistant, term) do
        Ash.Expr.expr(^base_expr and (^match_expr or uid == ^assistant_uid))
      else
        Ash.Expr.expr(^base_expr and ^match_expr)
      end
    end
  end

  defp principal_term_expr(true, contains_pattern, "", _uid_pattern) do
    Ash.Expr.expr(
      ilike(display_name, ^contains_pattern) or
        ilike(type(uid, :string), ^contains_pattern) or
        ilike(agent.role, ^contains_pattern)
    )
  end

  defp principal_term_expr(true, contains_pattern, _uid_term, uid_pattern) do
    Ash.Expr.expr(
      ilike(display_name, ^contains_pattern) or
        ilike(type(uid, :string), ^contains_pattern) or
        ilike(type(uid, :string), ^uid_pattern) or
        ilike(agent.role, ^contains_pattern)
    )
  end

  defp principal_term_expr(false, contains_pattern, "", _uid_pattern) do
    Ash.Expr.expr(
      ilike(display_name, ^contains_pattern) or
        ilike(type(uid, :string), ^contains_pattern) or
        ilike(human_user.email, ^contains_pattern) or
        ilike(human_user.job_title, ^contains_pattern) or
        ilike(agent.role, ^contains_pattern)
    )
  end

  defp principal_term_expr(false, contains_pattern, _uid_term, uid_pattern) do
    Ash.Expr.expr(
      ilike(display_name, ^contains_pattern) or
        ilike(type(uid, :string), ^contains_pattern) or
        ilike(human_user.email, ^contains_pattern) or
        ilike(human_user.job_title, ^contains_pattern) or
        ilike(type(uid, :string), ^uid_pattern) or
        ilike(agent.role, ^contains_pattern)
    )
  end

  defp assistant_alias_match?(nil, _term), do: false

  defp assistant_alias_match?(assistant, term) do
    needle = term |> String.trim_leading("@") |> String.downcase()

    Enum.any?(Ankole.Principals.assistant_aliases(assistant.principal), fn name ->
      String.contains?(String.downcase(name), needle)
    end)
  end

  defp mentionable_principal?(%{type: :human}), do: true

  defp mentionable_principal?(%{type: :agent, agent: %{type: type}})
       when type in [:ai_colleague, :personal_assistant], do: true

  defp mentionable_principal?(_), do: false

  defp principal_visible?(_principal, :all), do: true

  defp principal_visible?(%{uid: uid}, %MapSet{} = visible_uids),
    do: MapSet.member?(visible_uids, uid)

  defp score_principal_match(principal, needle, uid_needle, priority_uids, is_guest?) do
    fields = principal_search_fields(principal, is_guest?)
    tier = principal_match_tier(fields, needle, uid_needle)

    if tier == 0 do
      nil
    else
      sim = String.jaro_distance(fields.name, needle)
      boost = if MapSet.member?(priority_uids, principal.uid), do: 1.0, else: 0.0
      {tier, sim, boost}
    end
  end

  defp principal_search_fields(principal, is_guest?) do
    email =
      if is_guest?,
        do: "",
        else: String.downcase((principal.human_user && principal.human_user.email) || "")

    job =
      if is_guest?,
        do: "",
        else: String.downcase((principal.human_user && principal.human_user.job_title) || "")

    %{
      name: String.downcase(principal_display_name(principal)),
      email: email,
      email_local: email |> String.split("@", parts: 2) |> List.first(""),
      job: job,
      uid: principal.uid,
      role: String.downcase((principal.agent && principal.agent.role) || "")
    }
  end

  defp principal_match_tier(fields, needle, uid_needle) do
    cond do
      exact_principal_match?(fields, needle, uid_needle) -> 4
      prefix_principal_match?(fields, needle, uid_needle) -> 3
      primary_substring_match?(fields, needle, uid_needle) -> 2
      secondary_substring_match?(fields, needle) -> 1
      true -> 0
    end
  end

  defp exact_principal_match?(fields, needle, uid_needle) do
    fields.name == needle or
      non_empty_equal?(fields.uid, uid_needle) or
      non_empty_equal?(fields.email_local, needle)
  end

  defp prefix_principal_match?(fields, needle, uid_needle) do
    String.starts_with?(fields.name, needle) or
      non_empty_prefix?(fields.uid, uid_needle) or
      non_empty_prefix?(fields.email, needle)
  end

  defp primary_substring_match?(fields, needle, uid_needle) do
    word_prefix_match?(fields.name, needle) or
      String.contains?(fields.name, needle) or
      non_empty_contains?(fields.uid, uid_needle)
  end

  defp secondary_substring_match?(fields, needle) do
    non_empty_contains?(fields.email, needle) or
      non_empty_contains?(fields.job, needle) or
      non_empty_contains?(fields.role, needle)
  end

  defp word_prefix_match?(text, needle) do
    text
    |> String.split(~r/[\s._-]+/, trim: true)
    |> Enum.any?(&String.starts_with?(&1, needle))
  end

  defp non_empty_equal?("", _needle), do: false
  defp non_empty_equal?(_text, ""), do: false
  defp non_empty_equal?(text, needle), do: text == needle

  defp non_empty_prefix?("", _needle), do: false
  defp non_empty_prefix?(_text, ""), do: false
  defp non_empty_prefix?(text, needle), do: String.starts_with?(text, needle)

  defp non_empty_contains?("", _needle), do: false
  defp non_empty_contains?(_text, ""), do: false
  defp non_empty_contains?(text, needle), do: String.contains?(text, needle)

  defp context_collaborator_uids(nil, _reachable), do: MapSet.new()

  defp context_collaborator_uids(page_id, reachable) do
    with {:ok, %Page{deleted_at: nil} = page} <- Pages.fetch(page_id),
         true <- band(Access.page_bits(page, reachable), 1) != 0 do
      content =
        PageContent
        |> Ash.Query.filter(page_id == ^page.id)
        |> Ash.Query.select([:page_id, :updated_by, :contributors])
        |> Ankole.Ash.read_one!()

      grant_uids =
        for grant <- Access.page_grants(page.id),
            not is_nil(grant.principal_uid),
            do: grant.principal_uid

      contributor_uids =
        if content do
          [page.created_by.uid, content.updated_by.uid | Enum.map(content.contributors, & &1.uid)]
        else
          [page.created_by.uid]
        end

      MapSet.new(grant_uids ++ contributor_uids)
    else
      _ -> MapSet.new()
    end
  end

  defp principal_candidate_json(principal, is_guest?) do
    %{
      principal_uid: principal.uid,
      kind: principal.type,
      name: principal_display_name(principal),
      avatar_url: principal.avatar_url,
      membership: principal.membership,
      email: if(is_guest?, do: nil, else: principal.human_user && principal.human_user.email),
      job_title:
        if(is_guest?, do: nil, else: principal.human_user && principal.human_user.job_title),
      aliases:
        if(principal.agent && principal.agent.type == :personal_assistant,
          do: Ankole.Principals.assistant_aliases(principal),
          else: []
        ),
      role: principal.agent && principal.agent.role
    }
  end

  defp principal_display_name(principal), do: Ankole.Principals.display_name(principal)

  # --- Resolution (Pages & Principals) ---

  defp resolve_pages(_actor, [], _reachable, _context), do: []

  defp resolve_pages(actor, page_ids, reachable, context) do
    valid_ids =
      for raw <- page_ids, {:ok, casted} <- [Ecto.UUID.cast(raw)], uniq: true, do: casted

    pages_by_id =
      if valid_ids == [] do
        %{}
      else
        Page
        |> Ash.Query.filter(id in ^valid_ids)
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1})
      end

    ancestor_map = load_ancestor_map(Map.values(pages_by_id))

    trashed_ids =
      for {_id, page} <- pages_by_id,
          not is_nil(page.deleted_at) and not any_ancestor_deleted?(page, ancestor_map),
          do: page.id

    trashed_reachable =
      if trashed_ids == [] do
        %{}
      else
        case Access.reachable_trashed(actor, trashed_ids, context: context) do
          {:ok, map} -> map
          _ -> %{}
        end
      end

    statuses_by_id =
      Map.new(pages_by_id, fn {id, page} ->
        {id, page_resolution_status(page, ancestor_map, reachable, trashed_reachable)}
      end)

    accessible_pages =
      for {id, status} <- statuses_by_id,
          status in [:ok, :trashed],
          do: Map.fetch!(pages_by_id, id)

    doc_ids = for %{type: :doc, id: id} <- accessible_pages, do: id

    excerpts_by_id =
      if doc_ids == [] do
        %{}
      else
        PageContent
        |> Ash.Query.filter(page_id in ^doc_ids)
        |> Ash.Query.select([:page_id, :plain_text])
        |> Ankole.Ash.read!()
        |> Map.new(fn row -> {row.page_id, excerpt_text(row.plain_text)} end)
      end

    file_ids = for %{type: :file, id: id} <- accessible_pages, do: id
    files_by_id = Files.primary_files_by_page(file_ids)

    Enum.map(page_ids, fn raw_id ->
      with {:ok, id} <- Ecto.UUID.cast(raw_id),
           %Page{} = page <- Map.get(pages_by_id, id),
           status when status in [:ok, :trashed] <- Map.get(statuses_by_id, id) do
        %{
          id: page.id,
          access: status,
          type: page.type,
          title: page.title,
          icon: page.icon,
          private_owner_uid: page.private_owner_uid,
          ancestors: readable_ancestor_titles(page, ancestor_map, reachable),
          updated_at: page.updated_at,
          excerpt: Map.get(excerpts_by_id, page.id),
          file: Map.get(files_by_id, page.id)
        }
      else
        _ -> restricted_page(raw_id)
      end
    end)
  end

  defp page_resolution_status(page, ancestor_map, reachable, trashed_reachable) do
    cond do
      any_ancestor_deleted?(page, ancestor_map) ->
        :restricted

      is_nil(page.deleted_at) ->
        if band(Access.page_bits(page, reachable), 1) != 0, do: :ok, else: :restricted

      true ->
        if band(Access.page_bits(page, trashed_reachable), 1) != 0,
          do: :trashed,
          else: :restricted
    end
  end

  defp restricted_page(id) do
    %{
      id: id,
      access: :restricted,
      type: nil,
      title: nil,
      icon: nil,
      private_owner_uid: nil,
      ancestors: nil,
      updated_at: nil,
      excerpt: nil,
      file: nil
    }
  end

  defp readable_mentions(:all, _page_id, _reachable), do: MapSet.new()
  defp readable_mentions(_uids, nil, _reachable), do: MapSet.new()

  defp readable_mentions(_uids, page_id, reachable) do
    with {:ok, page} <- Pages.fetch(page_id),
         {:ok, _} <- Access.authorize_reachable(page, "node_view", reachable) do
      content =
        PageContent
        |> Ash.Query.filter(page_id == ^page.id)
        |> Ash.Query.select([:content])
        |> Ankole.Ash.read_one!()

      comments =
        Ankole.Pod.PageComment
        |> Ash.Query.filter(page_id == ^page.id and is_nil(deleted_at))
        |> Ash.Query.select([:body])
        |> Ankole.Ash.read!()

      texts = [if(content, do: content.content, else: "") | Enum.map(comments, &(&1.body || ""))]

      Enum.reduce(texts, MapSet.new(), fn text, acc ->
        @principal_mention_regex
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.reduce(acc, &MapSet.put(&2, &1))
      end)
    else
      _ -> MapSet.new()
    end
  end

  defp resolve_principals([], _visible_uids, _readable_mentions), do: []

  defp resolve_principals(principal_uids, visible_uids, readable_mentions) do
    is_guest? = visible_uids != :all

    valid_uids =
      for raw <- principal_uids,
          {:ok, casted} <- [Ankole.Ecto.PrincipalKey.cast(raw)],
          uniq: true,
          do: casted

    principals_by_uid =
      if valid_uids == [] do
        %{}
      else
        Ankole.Principals.list_principals!(
          query: [
            filter: [uid: [in: valid_uids], type: [in: [:human, :agent]]],
            load: [:human_user, :agent]
          ]
        )
        |> Map.new(&{&1.uid, &1})
      end

    Enum.map(principal_uids, fn raw_uid ->
      with {:ok, uid} <- Ankole.Ecto.PrincipalKey.cast(raw_uid),
           %{} = principal <- Map.get(principals_by_uid, uid),
           true <- mentionable_principal?(principal),
           true <-
             principal_visible?(principal, visible_uids) or
               readable_assistant?(principal, readable_mentions) do
        principal
        |> principal_candidate_json(is_guest?)
        |> Map.put(:access, if(principal.status == :disabled, do: :disabled, else: :ok))
      else
        _ -> restricted_principal(raw_uid)
      end
    end)
  end

  defp readable_assistant?(%{uid: uid, agent: %{type: :personal_assistant}}, mentions),
    do: MapSet.member?(mentions, uid)

  defp readable_assistant?(_principal, _mentions), do: false

  defp restricted_principal(uid) do
    %{
      principal_uid: uid,
      access: :restricted,
      kind: nil,
      name: nil,
      avatar_url: nil,
      membership: nil,
      email: nil,
      job_title: nil,
      role: nil
    }
  end

  # --- Ancestors & Helpers ---

  defp load_ancestor_map([]), do: %{}

  defp load_ancestor_map(pages) do
    frontier =
      pages
      |> Enum.map(& &1.parent_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    fetch_ancestor_levels(frontier, %{}, 0)
  end

  defp fetch_ancestor_levels([], acc, _depth), do: acc
  defp fetch_ancestor_levels(_frontier, acc, depth) when depth >= 64, do: acc

  defp fetch_ancestor_levels(frontier, acc, depth) do
    missing = Enum.reject(frontier, &Map.has_key?(acc, &1))

    if missing == [] do
      acc
    else
      parents =
        Page
        |> Ash.Query.filter(id in ^missing)
        |> Ash.Query.select([
          :id,
          :parent_id,
          :title,
          :deleted_at,
          :acl_anchor_id,
          :is_acl_anchor
        ])
        |> Ankole.Ash.read!()

      next_acc =
        Enum.reduce(parents, acc, fn parent, map ->
          Map.put(map, parent.id, %{
            id: parent.id,
            parent_id: parent.parent_id,
            title: parent.title || "",
            deleted_at: parent.deleted_at,
            acl_anchor_id: parent.acl_anchor_id,
            is_acl_anchor: parent.is_acl_anchor
          })
        end)

      next_frontier =
        parents
        |> Enum.map(& &1.parent_id)
        |> Enum.reject(&(is_nil(&1) or Map.has_key?(next_acc, &1)))
        |> Enum.uniq()

      fetch_ancestor_levels(next_frontier, next_acc, depth + 1)
    end
  end

  defp any_ancestor_deleted?(page, ancestor_map) do
    walk_ancestors_deleted?(page.parent_id, ancestor_map, MapSet.new())
  end

  defp walk_ancestors_deleted?(nil, _ancestor_map, _seen), do: false

  defp walk_ancestors_deleted?(parent_id, ancestor_map, seen) do
    if MapSet.member?(seen, parent_id) do
      true
    else
      case Map.get(ancestor_map, parent_id) do
        nil ->
          true

        %{deleted_at: deleted_at} when not is_nil(deleted_at) ->
          true

        parent ->
          walk_ancestors_deleted?(parent.parent_id, ancestor_map, MapSet.put(seen, parent_id))
      end
    end
  end

  defp readable_ancestor_titles(page, ancestor_map, reachable) do
    collect_readable_ancestors(page.parent_id, ancestor_map, reachable, [], MapSet.new())
  end

  defp collect_readable_ancestors(nil, _ancestor_map, _reachable, chain, _seen), do: chain

  defp collect_readable_ancestors(parent_id, ancestor_map, reachable, chain, seen) do
    if MapSet.member?(seen, parent_id) do
      chain
    else
      case Map.get(ancestor_map, parent_id) do
        nil ->
          chain

        parent ->
          if is_nil(parent.deleted_at) and band(Access.page_bits(parent, reachable), 1) != 0 do
            collect_readable_ancestors(
              parent.parent_id,
              ancestor_map,
              reachable,
              [parent.title | chain],
              MapSet.put(seen, parent_id)
            )
          else
            chain
          end
      end
    end
  end

  defp excerpt_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, 300)
  end

  defp excerpt_text(_text), do: ""

  defp normalize_category(value) when value in [:all, "all", nil, ""], do: {:ok, :all}
  defp normalize_category(value) when value in [:page, "page"], do: {:ok, :page}
  defp normalize_category(value) when value in [:principal, "principal"], do: {:ok, :principal}
  defp normalize_category(_), do: {:error, :invalid_request}

  defp normalize_optional_uuid(nil), do: {:ok, nil}
  defp normalize_optional_uuid(""), do: {:ok, nil}

  defp normalize_optional_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_optional_uuid(_), do: {:error, :invalid_request}

  defp normalize_limit(nil), do: {:ok, @default_candidates_limit}

  defp normalize_limit(limit) when is_integer(limit) do
    {:ok, max(1, min(limit, @max_candidates_limit))}
  end

  defp normalize_limit(_), do: {:error, :invalid_request}

  defp normalize_id_list(nil), do: {:ok, []}

  defp normalize_id_list(list) when is_list(list) do
    if length(list) <= @max_resolve_ids and Enum.all?(list, &is_binary/1) do
      {:ok, Enum.uniq(list)}
    else
      {:error, :invalid_request}
    end
  end

  defp normalize_id_list(_), do: {:error, :invalid_request}
end
