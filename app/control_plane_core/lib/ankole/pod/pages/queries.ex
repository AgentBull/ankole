defmodule Ankole.Pod.Pages.Queries do
  @moduledoc "Owns visible page lists, directory cursors, search, and version snapshots."
  require Ash.Query
  alias Ankole.Repo
  alias Ankole.Pod.{Access, Page, Pages}

  def list_children(%Ankole.AuthZ.Actor{} = actor, parent_id, opts \\ %{}) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    Repo.transact_repeatable_read_only(fn ->
      with :ok <- visible_parent(actor, parent_id) do
        limit = Ankole.Attrs.get(opts, :limit, 200)
        limit = if is_integer(limit), do: max(1, min(limit, 200)), else: 200
        cursor = Ankole.Attrs.get(opts, :cursor)
        page_opts = if cursor, do: [limit: limit, after: cursor], else: [limit: limit]

        owner =
          if is_nil(parent_id) and to_string(Ankole.Attrs.get(opts, :scope, "space")) == "private",
            do: uid

        query = Page |> Ash.Query.for_read(if(parent_id, do: :list_children, else: :list_roots))

        query =
          if parent_id,
            do: Ash.Query.filter(query, parent_id == ^parent_id),
            else: Ash.Query.filter(query, is_nil(parent_id))

        query =
          cond do
            parent_id -> query
            owner -> Ash.Query.filter(query, private_owner_uid == ^owner)
            true -> Ash.Query.filter(query, is_nil(private_owner_uid))
          end

        query =
          query
          |> Ash.Query.sort(position: :asc, id: :asc)
          |> Ash.Query.select([
            :id,
            :tenant_id,
            :parent_id,
            :private_owner_uid,
            :position,
            :title,
            :icon,
            :type,
            :acl_anchor_id,
            :inherit_permissions
          ])

        with {:ok, page} <- Ankole.Ash.read_authorized(query, actor, page: page_opts) do
          next = if page.more?, do: List.last(page.results).__metadata__.keyset

          {:ok,
           %{
             pages: page.results,
             next_cursor: next,
             principal_uid: uid,
             can_create_private: can_create_private?(actor),
             can_create_space: Pages.can_create_space?(actor)
           }}
        end
      end
    end)
  end

  def search(%Ankole.AuthZ.Actor{} = actor, query, opts \\ %{}) do
    Repo.transact_repeatable_read_only(fn -> search_pages(actor, query, opts) end)
  end

  defp search_pages(%Ankole.AuthZ.Actor{} = actor, query, opts) when is_binary(query) do
    pattern = "%" <> Repo.escape_like(String.trim(query)) <> "%"

    query =
      Page
      |> Ash.Query.for_read(:search, %{
        required_action: Ankole.Attrs.get(opts, :required_action, :page_view)
      })
      |> Ash.Query.filter(ilike(title, ^pattern) or exists(content, ilike(plain_text, ^pattern)))
      |> Ash.Query.calculate(
        :relevance,
        :float,
        Ash.Expr.expr(fragment("similarity(?, ?::text)", title, ^String.trim(query)))
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
         {:ok, pages} <- read_pages(query, actor),
         do:
           {:ok,
            %{
              pages: pages,
              principal_uid: Ankole.AuthZ.Actor.uid(actor),
              can_create_private: can_create_private?(actor),
              can_create_space: Pages.can_create_space?(actor)
            }}
  end

  defp search_pages(_actor, _query, _opts), do: {:error, :invalid_request}

  defp exclude_subtree(query, nil), do: {:ok, query}

  defp exclude_subtree(query, source_id) do
    with {:ok, source_id} <- Ecto.UUID.cast(source_id) do
      tenant_id = Repo.tenant_id!()

      {:ok,
       Ash.Query.filter(
         query,
         fragment(
           """
           ? NOT IN (
             WITH RECURSIVE subtree AS (
               SELECT source.id FROM pages source
               WHERE source.tenant_id = ?::text::uuid AND source.id = ?::text::uuid
               UNION ALL
               SELECT child.id FROM pages child
               JOIN subtree parent ON child.parent_id = parent.id
               WHERE child.tenant_id = ?::text::uuid
             )
             SELECT id FROM subtree
           )
           """,
           id,
           ^tenant_id,
           ^source_id,
           ^tenant_id
         )
       )}
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
          pages = Map.new(pages, &{&1.id, &1})
          {:ok, Enum.flat_map(ids, fn id -> if page = pages[id], do: [page], else: [] end)}
      end
    end
  end

  defp list_query(scope, actor, term) when scope in ["recent", "favorites"] do
    with {:ok, reachable} <- Access.reachable_anchors(actor) do
      ids = state_page_ids(scope, actor, term, reachable)

      query =
        Page |> Ash.Query.filter(id in ^ids) |> Ash.Query.set_context(%{pod_state_order: ids})

      {:ok, query}
    end
  end

  defp list_query("shared", actor, _term) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, context} <- Access.context_snapshot(actor),
         {:ok, reachable} <- Access.reachable_anchors(actor, context: context),
         {:ok, shared} <- Access.directly_shared_ids(actor, reachable, context: context) do
      shared = shared_root_ids(shared, reachable)

      {:ok,
       Ash.Query.filter(
         Page,
         id in ^shared and (is_nil(private_owner_uid) or private_owner_uid != ^uid)
       )}
    end
  end

  defp list_query(scope, actor, _term) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    case scope do
      "space" -> {:ok, Ash.Query.filter(Page, is_nil(parent_id) and is_nil(private_owner_uid))}
      "private" -> {:ok, Ash.Query.filter(Page, is_nil(parent_id) and private_owner_uid == ^uid)}
      _ -> {:ok, Ash.Query.filter(Page, is_nil(parent_id) or id == acl_anchor_id)}
    end
  end

  defp filter_list_title(query, term) when is_binary(term) do
    pattern = "%#{Repo.escape_like(String.trim(term))}%"

    Ash.Query.filter(
      query,
      ilike(title, ^pattern) or exists(content, ilike(plain_text, ^pattern))
    )
  end

  defp filter_list_title(query, _term), do: query

  defp state_page_ids(scope, actor, term, reachable) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    {anchors, own} = Access.visibility_ids(reachable)
    field = if scope == "recent", do: "visited_at", else: "favorited_at"
    term = if is_binary(term), do: Repo.escape_like(String.trim(term))

    Repo.query!(
      """
      SELECT p.id::text FROM page_user_states state
      JOIN pages p ON p.tenant_id = $1::text::uuid AND p.id = state.page_id
      LEFT JOIN page_contents pc ON pc.tenant_id = p.tenant_id AND pc.page_id = p.id
      WHERE state.tenant_id = $1::text::uuid AND state.principal_uid = $2::text
        AND state.#{field} IS NOT NULL AND p.deleted_at IS NULL
        AND (p.acl_anchor_id = ANY($3::text[]::uuid[]) OR p.id = ANY($4::text[]::uuid[]))
        AND ($5::text IS NULL OR p.title ILIKE ('%' || $5::text || '%')
          OR pc.plain_text ILIKE ('%' || $5::text || '%'))
      ORDER BY state.#{field} DESC, p.id LIMIT 200
      """,
      [Repo.tenant_id!(), uid, anchors, own, term]
    ).rows
    |> Enum.map(&hd/1)
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
           Ankole.Pod.Access.Graph.project_permissions(Map.fetch!(by_id, id), bits)
         end)}
      else
        [id, deleted_at] = List.last(candidates)
        list_trash(actor, term, context, {deleted_at, id}, collected)
      end
    end
  end

  defp trash_candidates(term, {deleted_at, id}) do
    term = if is_binary(term), do: Repo.escape_like(String.trim(term))

    Repo.query!(
      """
      WITH RECURSIVE hidden_anchors AS (
        SELECT child.id FROM pages child
        JOIN pages parent ON parent.tenant_id = $1::text::uuid
          AND parent.id = child.parent_anchor_id AND parent.deleted_at IS NOT NULL
        WHERE child.tenant_id = $1::text::uuid AND child.is_acl_anchor
        UNION
        SELECT child.id FROM pages child JOIN hidden_anchors h ON child.parent_anchor_id = h.id
        WHERE child.tenant_id = $1::text::uuid AND child.is_acl_anchor
      )
      SELECT p.id::text, p.deleted_at FROM pages p
      LEFT JOIN page_contents pc ON pc.tenant_id = p.tenant_id AND pc.page_id = p.id
      WHERE p.tenant_id = $1::text::uuid AND p.deleted_at IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM hidden_anchors h WHERE h.id = p.id)
        AND ($2::timestamp IS NULL OR p.deleted_at < $2::timestamp
          OR (p.deleted_at = $2::timestamp AND p.id > $3::text::uuid))
        AND ($4::text IS NULL OR p.title ILIKE ('%' || $4::text || '%')
          OR pc.plain_text ILIKE ('%' || $4::text || '%'))
      ORDER BY p.deleted_at DESC, p.id LIMIT 200
      """,
      [Repo.tenant_id!(), deleted_at, id, term]
    ).rows
  end

  defp shared_root_ids(ids, reachable) do
    {anchors, own} = Access.visibility_ids(reachable)

    Repo.query!(
      """
      SELECT p.id::text FROM pages p
      LEFT JOIN pages parent ON parent.tenant_id = $1::text::uuid AND parent.id = p.parent_id
      WHERE p.tenant_id = $1::text::uuid AND p.id = ANY($2::text[]::uuid[])
        AND (parent.id IS NULL OR NOT (parent.acl_anchor_id = ANY($3::text[]::uuid[])
          OR parent.id = ANY($4::text[]::uuid[])))
      """,
      [Repo.tenant_id!(), ids, anchors, own]
    ).rows
    |> Enum.map(&hd/1)
  end

  def can_create_private?(%Ankole.AuthZ.Actor{} = actor) do
    match?({:ok, %{type: :human, membership: :member}}, Access.principal(actor))
  end

  defp visible_parent(_actor, nil), do: :ok

  defp visible_parent(actor, id) do
    with {:ok, _} <- Pages.authorize(actor, id, "page_view"), do: :ok
  end

  def reconcile_versions(%Ankole.AuthZ.Actor{} = actor, page_ids, table_ids)
      when is_list(page_ids) and is_list(table_ids) do
    Repo.transact_repeatable_read_only(fn ->
      with {:ok, reachable} <- Access.reachable_anchors(actor) do
        ids = for id <- Enum.uniq(page_ids), {:ok, id} <- [Ecto.UUID.cast(id)], do: id
        pages = Page |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.read!()

        pages =
          for page <- pages,
              Bitwise.band(Access.page_bits(page, reachable), 1) != 0,
              do: Map.take(page, [:id, :revision])

        tables = Ankole.Pod.Database.reconcile_versions(table_ids, reachable)

        {:ok, %{pages: pages, tables: tables}}
      end
    end)
  end

  def reconcile_versions(_uid, _pages, _tables), do: {:error, :invalid_request}
end
