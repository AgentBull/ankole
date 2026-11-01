defmodule Ankole.Pod.Pages.Queries do
  @moduledoc "Owns visible page lists, directory cursors, search, and version snapshots."
  require Ash.Expr
  require Ash.Query
  alias Ankole.Repo
  alias Ankole.Files.Access
  alias Ankole.Pod.{Files, Page, PageContent, Pages}

  def list_children(%Ankole.AuthZ.Actor{} = actor, parent_id, opts \\ %{}) do
    Repo.transact_repeatable_read_only(fn ->
      with {:ok, access} <- Ankole.Files.Access.Graph.navigation_access(actor),
           policy = Ankole.AuthZ.Checks.DriveAnchorFilter.policy(access.reachable),
           :ok <- visible_directory_parent(actor, parent_id, policy),
           {:ok, directory} <- read_directory(actor, parent_id, opts, access, policy) do
        if Ankole.Attrs.get(opts, :details, false) in [true, "true"] do
          {:ok, Map.put(directory, :details, child_details(directory.pages))}
        else
          {:ok, directory}
        end
      end
    end)
  end

  def visible_child_count_in_tx(%Ankole.AuthZ.Actor{} = actor, %Page{} = page, reachable) do
    if is_nil(page.deleted_at) do
      Page
      |> Ash.Query.filter(parent_id == ^page.id)
      |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(
        actor,
        Ankole.AuthZ.Checks.DriveAnchorFilter.policy(reachable)
      )
      |> Ankole.Ash.count!(actor: actor, authorize?: true)
    else
      0
    end
  end

  @doc """
  The ancestors of `page` from the root down to its parent that `actor` can read. The path stops at the
  nearest unreadable ancestor and starts below it, so a shared page under a private parent shows only the
  pages its reader can open.
  """
  def readable_ancestors_in_tx(%Ankole.AuthZ.Actor{} = actor, %Page{} = page, reachable) do
    with {:ok, path} <- Access.path(page),
         ids = path |> Enum.drop(-1) |> Enum.reject(&is_nil(&1.parent_id)) |> Enum.map(& &1.id),
         {:ok, readable} <-
           Page
           |> Ash.Query.filter(id in ^ids)
           |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(
             actor,
             Ankole.AuthZ.Checks.DriveAnchorFilter.policy(reachable)
           )
           |> Ankole.Ash.read_authorized(actor) do
      by_id = Map.new(readable, &{&1.id, &1})

      {:ok,
       ids
       |> Enum.reverse()
       |> Enum.reduce_while([], fn id, chain ->
         case by_id do
           %{^id => ancestor} -> {:cont, [ancestor | chain]}
           _unreadable -> {:halt, chain}
         end
       end)}
    end
  end

  def navigation(%Ankole.AuthZ.Actor{} = actor, active_page_id) do
    Repo.transact_repeatable_read_only(fn ->
      with {:ok, access} <- Ankole.Files.Access.Graph.navigation_access(actor),
           policy = Ankole.AuthZ.Checks.DriveAnchorFilter.policy(access.reachable),
           {:ok, space} <- read_directory(actor, nil, %{scope: "space"}, access, policy),
           {:ok, private} <- read_directory(actor, nil, %{scope: "private"}, access, policy) do
        path = navigation_path(active_page_id, access.reachable)

        root =
          case Ankole.Files.root(active_page_id) do
            {:ok, root} -> root
            _ -> nil
          end

        path =
          if root &&
               root.private_owner_uid not in [
                 nil,
                 Ankole.Principals.authority_uid(Ankole.AuthZ.Actor.uid(actor))
               ],
             do: [],
             else: path

        ids = Enum.map(path, & &1.id)

        path_query =
          Page
          |> Ash.Query.filter(id in ^ids)
          |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(actor, policy)
          |> Ash.Query.aggregate(:has_children, :exists, :children,
            query: [filter: policy.filter],
            authorize?: false
          )

        path_pages =
          if ids == [],
            do: %{},
            else:
              Ankole.Ash.read!(path_query, actor: actor, authorize?: true)
              |> Map.new(&{&1.id, &1})

        path = Enum.map(path, &Map.fetch!(path_pages, &1.id))
        scope = if root && root.private_owner_uid, do: "private", else: "space"

        Enum.reduce_while(Enum.drop(path, -1), {:ok, []}, fn parent, {:ok, directories} ->
          case read_directory(actor, parent.id, %{}, access, policy) do
            {:ok, directory} ->
              {:cont,
               {:ok, [Map.merge(directory, %{parent_id: parent.id, scope: scope}) | directories]}}

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, directories} ->
            {:ok,
             %{
               directories: [
                 Map.merge(space, %{parent_id: nil, scope: "space"}),
                 Map.merge(private, %{parent_id: nil, scope: "private"})
                 | Enum.reverse(directories)
               ],
               path: path
             }}

          error ->
            error
        end
      end
    end)
  end

  def navigation_entries(actor, ids) do
    Repo.transact_repeatable_read_only(fn ->
      with {:ok, access} <- Ankole.Files.Access.Graph.navigation_access(actor) do
        policy = Ankole.AuthZ.Checks.DriveAnchorFilter.policy(access.reachable)

        Page
        |> Ash.Query.filter(id in ^ids)
        |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(actor, policy)
        |> Ash.Query.aggregate(:has_children, :exists, :children,
          query: [filter: policy.filter],
          authorize?: false
        )
        |> Ash.Query.aggregate(:child_count, :count, :children,
          query: [filter: policy.filter],
          authorize?: false
        )
        |> Ankole.Ash.read_authorized(actor)
      end
    end)
  end

  defp navigation_path(nil, _reachable), do: []

  defp navigation_path(id, reachable) do
    with {:ok, page} <- Pages.fetch(id),
         {:ok, path} <- Access.path(page),
         true <-
           Enum.all?(
             path,
             &(is_nil(&1.deleted_at) and Bitwise.band(Access.page_bits(&1, reachable), 1) != 0)
           ) do
      Enum.reject(path, &is_nil(&1.parent_id))
    else
      _ -> []
    end
  end

  defp visible_directory_parent(_actor, nil, _policy), do: :ok

  defp visible_directory_parent(actor, id, policy) do
    query =
      Page
      |> Ash.Query.filter(id == ^id)
      |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(actor, policy)

    case Ankole.Ash.read_one_authorized(query, actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, _page} -> :ok
      error -> error
    end
  end

  defp read_directory(actor, parent_id, opts, access, policy) do
    uid = Ankole.Principals.authority_uid(Ankole.AuthZ.Actor.uid(actor))
    limit = Ankole.Attrs.get(opts, :limit, 200)
    limit = if is_integer(limit), do: max(1, min(limit, 200)), else: 200
    cursor = Ankole.Attrs.get(opts, :cursor)
    page_opts = if cursor, do: [limit: limit, after: cursor], else: [limit: limit]

    owner =
      if is_nil(parent_id) and to_string(Ankole.Attrs.get(opts, :scope, "space")) == "private",
        do: uid

    query = Page |> Ash.Query.for_read(if(parent_id, do: :list_children, else: :list_roots))

    root = if owner, do: Ankole.Files.private_root(owner), else: Ankole.Files.public_root()

    parent_id =
      parent_id ||
        case root do
          {:ok, node} -> node.id
          _ -> nil
        end

    query =
      if parent_id,
        do: Ash.Query.filter(query, parent_id == ^parent_id),
        else: Ash.Query.filter(query, false)

    query =
      query
      |> Ash.Query.sort(position: :asc_nils_last, name: :asc, id: :asc)
      |> Ash.Query.select([
        :id,
        :tenant_id,
        :parent_id,
        :private_owner_uid,
        :position,
        :name,
        :title,
        :icon,
        :type,
        :acl_anchor_id,
        :inherit_permissions
      ])
      |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(actor, policy)
      # Apply the caller's visibility filter without resolving grants again.
      |> Ash.Query.aggregate(:has_children, :exists, :children,
        query: [filter: policy.filter],
        authorize?: false
      )

    with {:ok, page} <- Ankole.Ash.read_authorized(query, actor, page: page_opts) do
      {:ok,
       %{
         pages: page.results,
         next_cursor: if(page.more?, do: List.last(page.results).__metadata__.keyset),
         principal_uid: uid,
         can_create_private: can_create_private?(actor),
         can_create_space: Bitwise.band(access.space_bits, 4) != 0,
         can_manage_space: access.can_manage_space
       }}
    end
  end

  defp child_details([]), do: %{}

  defp child_details(pages) do
    ids = Enum.map(pages, & &1.id)

    meta_by_id =
      Page
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :created_at, :updated_at, :created_by])
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.id, &1})

    creator_uids =
      meta_by_id
      |> Map.values()
      |> Enum.flat_map(fn row -> if row.created_by, do: [row.created_by.uid], else: [] end)
      |> Enum.uniq()

    names_by_uid =
      Ankole.Principals.list_principals!(
        query: [filter: [uid: [in: creator_uids]], select: [:uid, :display_name]]
      )
      |> Map.new(&{&1.uid, &1.display_name})

    doc_ids = for %{type: :doc, id: id} <- pages, do: id

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

    file_ids = for %{type: :file, id: id} <- pages, do: id
    files_by_id = Files.primary_files_by_page(file_ids)

    Map.new(pages, fn page ->
      meta = Map.fetch!(meta_by_id, page.id)
      creator_uid = meta.created_by && meta.created_by.uid

      {page.id,
       %{
         created_at: meta.created_at,
         updated_at: meta.updated_at,
         created_by: creator_uid,
         creator_name: Map.get(names_by_uid, creator_uid),
         excerpt: Map.get(excerpts_by_id, page.id),
         file: Map.get(files_by_id, page.id)
       }}
    end)
  end

  defp excerpt_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, 300)
  end

  defp excerpt_text(_text), do: ""

  def search(%Ankole.AuthZ.Actor{} = actor, query, opts \\ %{}) do
    Repo.transact_repeatable_read_only(fn -> search_pages(actor, query, opts) end)
  end

  defp search_pages(%Ankole.AuthZ.Actor{} = actor, query, opts) when is_binary(query) do
    term = String.trim(query)

    query =
      Page
      |> Ash.Query.filter(not is_root)
      |> Ash.Query.for_read(:search, %{
        required_action: Ankole.Attrs.get(opts, :required_action, :node_view)
      })
      |> maybe_filter_embeddable(Ankole.Attrs.get(opts, :embeddable, false))
      |> filter_text(term)
      |> Ash.Query.calculate(
        :relevance,
        :float,
        Ash.Expr.expr(fragment("similarity(?, ?::text)", title, ^term))
      )
      |> then(fn built ->
        Ash.Query.sort(built, [
          {built.calculations.relevance, :desc},
          {:updated_at, :desc},
          {:id, :asc}
        ])
      end)
      |> Ash.Query.limit(30)

    with {:ok, query} <- exclude_subtree(query, Ankole.Attrs.get(opts, :exclude_subtree_of)),
         {:ok, reachable} <- Access.reachable_anchors(actor),
         policy =
           Ankole.AuthZ.Checks.DriveAnchorFilter.policy(
             reachable,
             Ankole.Attrs.get(opts, :required_action, :node_view)
           ),
         query = Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(query, actor, policy),
         {:ok, pages} <- read_search_pages(query, actor, term),
         {:ok, ancestors} <- ancestors(actor, pages),
         do:
           {:ok,
            %{
              pages: pages,
              ancestors: ancestors,
              principal_uid: Ankole.AuthZ.Actor.uid(actor),
              can_create_private: can_create_private?(actor),
              can_create_space: Pages.can_create_space?(actor)
            }}
  end

  defp search_pages(_actor, _query, _opts), do: {:error, :invalid_request}

  @doc "Counts the live descendants of a Page that the actor can view, for the Trash notice."
  def visible_descendant_count(%Ankole.AuthZ.Actor{} = actor, id) do
    {:ok, pages} =
      Repo.transact_repeatable_read_only(fn ->
        ids = id |> Ankole.Files.descendant_node_ids() |> List.delete(id)

        query =
          Page
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id in ^ids and is_nil(deleted_at))
          |> Ash.Query.select([:id])

        Ankole.Ash.read_authorized(query, actor)
      end)

    length(pages)
  end

  defp read_search_pages(query, actor, ""), do: read_pages(query, actor)

  defp read_search_pages(query, actor, term) do
    tenant = Repo.tenant_id!()
    patterns = text_patterns(term)

    # Every result matches at least one word in an indexed branch. Each branch
    # applies the same all-word filter, authorization, exclusions, ordering, and
    # limit, so merging their bounded results preserves the global ranking.
    branches = [
      Ash.Query.filter(
        query,
        type in [:doc, :base, :applet] and
          fragment(
            "/* pod_search:title */ ? IN (SELECT p.id FROM pages p WHERE p.tenant_id = ?::text::uuid AND p.title ILIKE ANY(?::text[]))",
            id,
            ^tenant,
            ^patterns
          )
      ),
      Ash.Query.filter(
        query,
        type in [:file, :folder] and
          fragment("/* pod_search:name */ ? ILIKE ANY(?::text[])", name, ^patterns)
      ),
      Ash.Query.filter(
        query,
        fragment(
          "/* pod_search:body */ ? IN (SELECT c.page_id FROM page_contents c WHERE c.tenant_id = ?::text::uuid AND c.plain_text ILIKE ANY(?::text[]))",
          id,
          ^tenant,
          ^patterns
        )
      )
    ]

    branches
    |> Enum.reduce_while({:ok, []}, fn branch, {:ok, matches} ->
      case read_pages(branch, actor) do
        {:ok, pages} -> {:cont, {:ok, matches ++ pages}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pages} ->
        {:ok, pages |> Enum.uniq_by(& &1.id) |> Enum.sort(&search_before?/2) |> Enum.take(30)}

      error ->
        error
    end
  end

  defp search_before?(left, right) do
    left_relevance = Map.fetch!(left.calculations, :relevance)
    right_relevance = Map.fetch!(right.calculations, :relevance)

    if left_relevance == right_relevance do
      case DateTime.compare(left.updated_at, right.updated_at) do
        :eq -> left.id <= right.id
        :gt -> true
        :lt -> false
      end
    else
      left_relevance > right_relevance
    end
  end

  defp maybe_filter_embeddable(query, true),
    do: Ash.Query.filter(query, type in [:base, :file, :applet])

  defp maybe_filter_embeddable(query, _embeddable), do: query

  defp ancestors(actor, pages) do
    ids = Ankole.Files.ancestor_node_ids(Enum.map(pages, & &1.id))
    Page |> Ash.Query.filter(id in ^ids) |> read_pages(actor)
  end

  defp exclude_subtree(query, nil), do: {:ok, query}

  defp exclude_subtree(query, source_id) do
    with {:ok, source_id} <- Ecto.UUID.cast(source_id) do
      excluded = Ankole.Files.descendant_node_ids(source_id)
      {:ok, Ash.Query.filter(query, id not in ^excluded)}
    else
      :error -> {:error, :invalid_request}
    end
  end

  def list(%Ankole.AuthZ.Actor{} = actor, opts \\ %{}) do
    Repo.transact_repeatable_read_only(fn -> list_in_snapshot(actor, opts) end)
  end

  defp list_in_snapshot(%Ankole.AuthZ.Actor{} = actor, opts) do
    scope = to_string(Ankole.Attrs.get(opts, :scope, "all"))
    term = Ankole.Attrs.get(opts, :query)

    if scope == "trash" do
      with {:ok, context} <- Access.context_snapshot(actor),
           do: list_trash(actor, term, context, {nil, nil}, [])
    else
      with {:ok, query} <- list_query(scope, actor, term) do
        query
        |> filter_list_title(term)
        |> Ash.Query.sort(updated_at: :desc, id: :asc)
        |> Ash.Query.limit(200)
        |> read_pages(actor)
      end
    end
  end

  defp read_pages(query, actor) do
    with {:ok, pages} <- Ankole.Ash.read_authorized(query, actor) do
      case query.context[:pod_state_order] do
        nil ->
          {:ok, pages}

        ids ->
          visited_at = query.context[:pod_visited_at] || %{}
          pages = Map.new(pages, &{&1.id, &1})

          {:ok,
           Enum.flat_map(ids, fn id ->
             if page = pages[id] do
               [%{page | visited_at: Map.get(visited_at, id)}]
             else
               []
             end
           end)}
      end
    end
  end

  defp list_query(scope, actor, term) when scope in ["recent", "favorites"] do
    with {:ok, reachable} <- Access.reachable_anchors(actor) do
      rows = state_page_ids(scope, actor, term, reachable)
      ids = Enum.map(rows, &elem(&1, 0))
      visited_at = Map.new(rows)

      query =
        Page
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.set_context(%{pod_state_order: ids, pod_visited_at: visited_at})
        |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(
          actor,
          Ankole.AuthZ.Checks.DriveAnchorFilter.policy(reachable)
        )

      {:ok, query}
    end
  end

  defp list_query("shared", actor, _term) do
    uid = Ankole.Principals.authority_uid(Ankole.AuthZ.Actor.uid(actor))

    with {:ok, context} <- Access.context_snapshot(actor),
         {:ok, reachable} <- Access.reachable_anchors(actor, context: context),
         {:ok, shared} <- Access.directly_shared_ids(actor, reachable, context: context) do
      shared = shared_root_ids(shared, reachable)

      {:ok,
       Page
       |> Ash.Query.filter(
         id in ^shared and (is_nil(private_owner_uid) or private_owner_uid != ^uid)
       )
       |> Ankole.AuthZ.Checks.DriveAnchorFilter.apply_policy(
         actor,
         Ankole.AuthZ.Checks.DriveAnchorFilter.policy(reachable)
       )}
    end
  end

  defp list_query(scope, actor, _term) do
    case scope do
      "space" ->
        root_query(Ankole.Files.public_root())

      "private" ->
        root_query(
          Ankole.Files.private_root(
            Ankole.Principals.authority_uid(Ankole.AuthZ.Actor.uid(actor))
          )
        )

      _ ->
        {:ok, Ash.Query.filter(Page, not is_root)}
    end
  end

  defp root_query({:ok, root}), do: {:ok, Ash.Query.filter(Page, parent_id == ^root.id)}
  defp root_query(_), do: {:ok, Ash.Query.filter(Page, false)}

  defp filter_list_title(query, term) when is_binary(term), do: filter_text(query, term)
  defp filter_list_title(query, _term), do: query

  # Every whitespace-separated word must appear in the title or the body, in any order.
  defp filter_text(query, text) do
    Enum.reduce(text_patterns(text) || [], query, fn pattern, query ->
      Ash.Query.filter(
        query,
        ilike(title, ^pattern) or exists(content, ilike(plain_text, ^pattern))
      )
    end)
  end

  # Each word adds a condition, so a pasted paragraph uses only its first 16 distinct words.
  defp text_patterns(text) when is_binary(text) do
    case text |> String.split() |> Enum.uniq() |> Enum.take(16) do
      [] -> nil
      words -> Enum.map(words, &("%" <> Repo.escape_like(&1) <> "%"))
    end
  end

  defp text_patterns(_text), do: nil

  defp state_page_ids(scope, actor, term, reachable) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    visible = Ankole.Files.visible_node_ids(reachable)
    field = if scope == "recent", do: "visited_at", else: "favorited_at"

    Repo.query!(
      """
      SELECT p.id::text, state.visited_at FROM page_user_states state
      JOIN pod_page_nodes p ON p.tenant_id = $1::text::uuid AND p.id = state.page_id
      LEFT JOIN page_contents pc ON pc.tenant_id = p.tenant_id AND pc.page_id = p.id
      WHERE state.tenant_id = $1::text::uuid AND state.principal_uid = $2::text
        AND state.#{field} IS NOT NULL AND p.deleted_at IS NULL
        AND p.id = ANY($3::text[]::uuid[])
        AND ($4::text[] IS NULL OR (SELECT bool_and(p.title ILIKE word OR COALESCE(pc.plain_text, '') ILIKE word)
          FROM unnest($4::text[]) word))
      ORDER BY state.#{field} DESC, p.id LIMIT 200
      """,
      [Repo.tenant_id!(), uid, visible, text_patterns(term)]
    ).rows
    |> Enum.map(fn [id, visited_at] -> {id, visited_at} end)
  end

  defp list_trash(%Ankole.AuthZ.Actor{} = actor, term, context, cursor, collected) do
    candidates = trash_candidates(term, cursor)
    ids = Enum.map(candidates, fn [id, _] -> id end)

    with {:ok, reachable} <- Access.reachable_trashed(actor, ids, context: context) do
      allowed =
        Enum.flat_map(ids, fn id ->
          case Map.get(reachable, id) do
            nil -> []
            bits -> if Bitwise.band(bits.self_bits, 8) != 0, do: [{id, bits.self_bits}], else: []
          end
        end)

      collected = collected ++ allowed

      if length(collected) >= 200 or length(candidates) < 200 do
        allowed = Enum.take(collected, 200)
        ids = Enum.map(allowed, &elem(&1, 0))
        pages = Page |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.read!()
        by_id = Map.new(pages, &{&1.id, &1})

        {:ok,
         Enum.map(allowed, fn {id, bits} ->
           Ankole.Files.Access.Graph.project_permissions(Map.fetch!(by_id, id), bits)
         end)}
      else
        [id, deleted_at] = List.last(candidates)
        list_trash(actor, term, context, {deleted_at, id}, collected)
      end
    end
  end

  defp trash_candidates(term, {deleted_at, id}) do
    Repo.query!(
      """
      SELECT p.id::text, p.deleted_at FROM pod_page_nodes p
      LEFT JOIN page_contents pc ON pc.tenant_id = p.tenant_id AND pc.page_id = p.id
      WHERE p.tenant_id = $1::text::uuid AND p.deleted_at IS NOT NULL
        AND NOT (p.id = ANY($5::text[]::uuid[]))
        AND ($2::timestamp IS NULL OR p.deleted_at < $2::timestamp
          OR (p.deleted_at = $2::timestamp AND p.id > $3::text::uuid))
        AND ($4::text[] IS NULL OR (SELECT bool_and(p.title ILIKE word OR COALESCE(pc.plain_text, '') ILIKE word)
          FROM unnest($4::text[]) word))
      ORDER BY p.deleted_at DESC, p.id LIMIT 200
      """,
      [
        Repo.tenant_id!(),
        deleted_at,
        id,
        text_patterns(term),
        Ankole.Files.hidden_trashed_node_ids()
      ]
    ).rows
  end

  defp shared_root_ids(ids, reachable), do: Ankole.Files.shared_root_node_ids(ids, reachable)

  def can_create_private?(%Ankole.AuthZ.Actor{} = actor) do
    match?({:ok, %{type: :human, membership: :member}}, Access.principal(actor))
  end

  def reconcile_versions(%Ankole.AuthZ.Actor{} = actor, page_ids, table_ids)
      when is_list(page_ids) and is_list(table_ids) do
    Repo.transact_top_level(fn ->
      with {:ok, reachable} <- Access.reachable_anchors(actor) do
        ids = for id <- Enum.uniq(page_ids), {:ok, id} <- [Ecto.UUID.cast(id)], do: id
        pages = Page |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.read!()

        pages =
          for page <- pages,
              Bitwise.band(Access.page_bits(page, reachable), 1) != 0,
              do: Map.take(page, [:id, :revision, :object_id])

        with {:ok, tables} <- Ankole.Pod.Bases.reconcile_versions(table_ids, reachable),
             do: {:ok, %{pages: pages, tables: tables}}
      end
    end)
  end

  def reconcile_versions(_uid, _pages, _tables), do: {:error, :invalid_request}
end
