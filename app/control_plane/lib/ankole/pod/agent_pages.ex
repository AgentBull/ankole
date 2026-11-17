defmodule Ankole.Pod.AgentPages do
  @moduledoc "Page operations use the executing Actor; Brain also applies the conversation disclosure boundary."
  require Ash.Query
  alias Ankole.{AuthZ, Kernel, Repo}
  alias Ankole.Brain.Access, as: KnowledgeAccess
  alias Ankole.Pod.Access
  alias Ankole.Pod.{Documents, Knowledge, Page, Pages}
  alias Ankole.AuthZ.Checks.PageAnchorFilter

  def read(actor, context, id, level \\ "L2") do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(id, :share),
           {:ok, reachable} <- visible(context, page),
           {:ok, detail} <- Pages.get_in_tx(actor, id),
           {:ok, projection} <- project(detail, level),
           {:ok, children} <- read_children_in_tx(actor, reachable, id, projection.level) do
        {:ok,
         summary(page)
         |> Map.put(:revision, page.revision)
         |> Map.merge(projection)
         |> Map.merge(children)}
      end
    end)
  end

  def children(actor, context, id, opts \\ %{})

  def children(actor, context, id, scope) when is_binary(scope),
    do: children(actor, context, id, %{"scope" => scope})

  def children(actor, context, nil, opts) when is_map(opts) do
    scope = Ankole.Attrs.get(opts, :scope, "space") || "space"
    depth = Ankole.Attrs.get(opts, :depth)

    cond do
      scope == "shared" ->
        with {:ok, reachable} <- business_visibility(context),
             {:ok, pages} <-
               Ankole.Pod.Pages.Queries.list(actor, %{reachable: reachable, scope: "shared"}),
             {:ok, entries} <-
               Ankole.Pod.Pages.Queries.navigation_entries(actor, Enum.map(pages, & &1.id)) do
          by_id = Map.new(entries, &{&1.id, &1})

          {:ok,
           Enum.flat_map(pages, fn page ->
             case Map.fetch(by_id, page.id) do
               {:ok, entry} -> [directory_summary(entry)]
               :error -> []
             end
           end)}
        end

      scope == "all" or (is_integer(depth) and depth > 1) ->
        with {:ok, reachable} <- business_visibility(context) do
          Ankole.Pod.Pages.Queries.tree(actor, %{
            reachable: reachable,
            scope: scope,
            depth: depth || 3
          })
        end

      true ->
        with {:ok, reachable} <- business_visibility(context),
             {:ok, directory} <-
               Ankole.Pod.Pages.Queries.list_children(actor, nil, %{
                 reachable: reachable,
                 scope: scope
               }),
             do: {:ok, Enum.map(directory.pages, &directory_summary/1)}
    end
  end

  def children(actor, context, id, opts) when is_map(opts) do
    depth = Ankole.Attrs.get(opts, :depth)

    if is_integer(depth) and depth > 1 do
      with {:ok, page} <- Pages.fetch(id),
           {:ok, reachable} <- visible(context, page) do
        Ankole.Pod.Pages.Queries.tree(actor, %{
          reachable: reachable,
          parent_id: id,
          depth: depth
        })
      end
    else
      Repo.transact_top_level(fn ->
        with {:ok, page} <- Pages.fetch(id),
             {:ok, reachable} <- visible(context, page),
             {:ok, children} <- children_in_tx(actor, reachable, id),
             do: {:ok, Enum.map(children, &directory_summary/1)}
      end)
    end
  end

  def save(actor, context, id, base_revision, markdown) do
    Access.write(
      actor.turn_authority,
      fn -> save_in_tx(actor, context, id, base_revision, markdown) end,
      after_commit: &Pages.committed_page(&1.page)
    )
  end

  def save_in_tx(actor, context, id, base_revision, markdown) do
    with {:ok, page} <- Pages.lock(id),
         :ok <- editable(actor, context, page),
         {:ok, parsed} <- Kernel.knowledge_parse(markdown),
         do:
           Knowledge.put_in_tx(id, parsed,
             actor: actor,
             context: context,
             base_revision: base_revision
           )
  end

  @doc false
  def save_page_in_tx(actor, context, id, base_revision, markdown)
      when is_integer(base_revision) and is_binary(markdown) do
    with {:ok, page} <- Pages.lock(id),
         :ok <- editable(actor, context, page) do
      case page.type do
        :knowledge ->
          with {:ok, parsed} <- Kernel.knowledge_parse(markdown),
               {:ok, %{page: updated_page}} <-
                 Knowledge.put_in_tx(id, parsed,
                   actor: actor,
                   context: context,
                   base_revision: base_revision
                 ) do
            {:ok, updated_page, fn -> Pages.committed_page(updated_page) end}
          end

        :doc ->
          with {:ok, %{result: %{page: updated_page}} = committed} <-
                 Documents.edit_markdown_in_tx(actor, id, base_revision, markdown, :write) do
            {:ok, updated_page, fn -> Documents.committed(committed) end}
          end

        _other ->
          {:error, :invalid_page_type}
      end
    end
  end

  def save_page_in_tx(_actor, _context, _id, _base_revision, _markdown),
    do: {:error, :invalid_request}

  def create(actor, context, parent_id, title, markdown) do
    Access.write_tree(
      actor.turn_authority,
      fn -> create_in_tx(actor, context, parent_id, title, markdown) end,
      root_ids: fn -> Ankole.Pod.Pages.Tree.root_ids([parent_id]) end,
      after_commit: &Pages.committed_tree/1
    )
  end

  def create_in_tx(actor, context, parent_id, title, markdown) do
    with {:ok, parent} <- Pages.fetch(parent_id),
         :ok <- editable(actor, context, parent),
         {:ok, parsed} <- Kernel.knowledge_parse(markdown),
         do:
           Pages.create_in_tx(
             actor,
             %{
               type: :knowledge,
               parent_id: parent_id,
               title: title,
               xml: parsed.xml,
               metadata: parsed.metadata
             },
             context: context
           )
  end

  @doc false
  def create_page_in_tx(actor, context, attrs) when is_map(attrs) do
    parent_id = attrs["parent_id"]
    title = attrs["title"] || ""
    markdown = attrs["markdown"] || ""

    with {:ok, parent} <- maybe_fetch_editable_parent(actor, context, parent_id),
         {:ok, page_type} <- resolve_create_page_type(attrs["type"], parent) do
      case page_type do
        "knowledge" ->
          if is_binary(parent_id) do
            with {:ok, parsed} <- Kernel.knowledge_parse(markdown),
                 {:ok, page} <-
                   Pages.create_in_tx(
                     actor,
                     %{
                       type: :knowledge,
                       parent_id: parent_id,
                       title: title,
                       xml: parsed.xml,
                       metadata: parsed.metadata
                     },
                     context: context
                   ) do
              created_page(actor, page)
            end
          else
            {:error, :invalid_page_domain}
          end

        "doc" ->
          doc_attrs =
            %{"type" => "doc", "title" => title}
            |> put_create_destination(actor, parent_id, attrs["scope"])

          with {:ok, parsed} <- Kernel.vfs_document_reconcile("<page />", markdown),
               {:ok, page} <-
                 Pages.create_in_tx(actor, Map.put(doc_attrs, "xml", parsed.xml),
                   context: context
                 ) do
            created_page(actor, page)
          end
      end
    end
  end

  defp created_page(actor, page) do
    {:ok, page,
     fn ->
       Pages.committed_tree(page)
       emit_page_created_telemetry(actor, page)
     end}
  end

  @doc false
  def create_destination_attrs(actor, attrs) do
    put_create_destination(%{}, actor, attrs["parent_id"], attrs["scope"])
  end

  defp maybe_fetch_editable_parent(_actor, _context, nil), do: {:ok, nil}

  defp maybe_fetch_editable_parent(actor, context, parent_id) do
    with {:ok, parent} <- Pages.fetch(parent_id),
         :ok <- editable(actor, context, parent) do
      {:ok, parent}
    end
  end

  defp resolve_create_page_type("knowledge", _parent), do: {:ok, "knowledge"}
  defp resolve_create_page_type("doc", _parent), do: {:ok, "doc"}

  defp resolve_create_page_type(nil, %{type: _} = parent),
    do: {:ok, if(Access.brain_page?(parent), do: "knowledge", else: "doc")}

  defp resolve_create_page_type(nil, nil), do: {:ok, "doc"}
  defp resolve_create_page_type(_other, _parent), do: {:error, :invalid_page_type}

  defp put_create_destination(attrs, _actor, parent_id, _scope) when is_binary(parent_id) do
    Map.put(attrs, "parent_id", parent_id)
  end

  defp put_create_destination(attrs, actor, nil, "private") do
    Map.put(
      attrs,
      "private_owner_uid",
      Ankole.Principals.authority_uid(AuthZ.Actor.uid(actor))
    )
  end

  defp put_create_destination(attrs, _actor, nil, _scope), do: attrs

  defp emit_page_created_telemetry(actor, page) do
    :telemetry.execute([:ankole, :pod, :page, :created], %{count: 1}, %{
      tenant_id: page.tenant_id,
      page_id: page.id,
      page_type: page.type,
      actor_type: Map.get(actor.principal, :type),
      actor_uid: AuthZ.Actor.uid(actor)
    })
  end

  @doc "Uses the executing Actor's permissions, with audience and requester checks for Brain."
  def editable(actor, context, page),
    do: authorize_change(actor, context, page, "node_edit")

  def authorize_change(actor, context, page, action, opts \\ []) do
    if Access.brain_page?(page) do
      KnowledgeAccess.authorize_change(actor, context, page, action, opts)
    else
      with {:ok, _} <- Access.authorize(actor, page, action, opts), do: :ok
    end
  end

  def business_visibility(context, opts \\ []) do
    with {:ok, principal} <- Ankole.Principals.get_principal(context.querier_uid),
         do:
           Access.reachable_anchors(
             AuthZ.Actor.new(principal, authn: Map.get(context, :authn, %{})),
             opts
           )
  end

  @doc "Combines business permissions with Brain disclosure for lists spanning both domains."
  def visibility(context, opts \\ []) do
    with {:ok, business} <- business_visibility(context, opts),
         {:ok, brain} <- KnowledgeAccess.visibility(context, opts) do
      ids =
        case Ankole.Pod.Pages.Tree.system_node("ankole_brain") do
          {:ok, root} -> Ankole.Pod.descendant_node_ids(root.id)
          {:error, :not_found} -> []
        end

      {:ok, Map.merge(Map.drop(business, ids), Map.take(brain, ids))}
    end
  end

  def visible(context, page, opts \\ []) do
    trash = Keyword.get(opts, :trash, false)
    graph_opts = if trash, do: [trash_page_ids: [page.id]], else: []

    visibility =
      if Access.brain_page?(page), do: &KnowledgeAccess.visibility/2, else: &business_visibility/2

    with {:ok, reachable} <- visibility.(context, graph_opts),
         {:ok, _} <- Access.authorize_reachable(page, "node_view", reachable, trash: trash),
         do: {:ok, reachable},
         else: (_ -> {:error, :not_found})
  end

  defp children_in_tx(actor, reachable, id) do
    policy = PageAnchorFilter.policy(reachable)

    Page
    |> Ash.Query.filter(parent_id == ^id)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> PageAnchorFilter.apply_policy(actor, policy)
    |> Ash.Query.aggregate(:has_children, :exists, :children,
      query: [filter: policy.filter],
      authorize?: false
    )
    |> Ankole.Ash.read_authorized(actor)
  end

  defp read_children_in_tx(_actor, _reachable, _id, "L0"), do: {:ok, %{}}

  defp read_children_in_tx(actor, reachable, id, _level) do
    with {:ok, children} <- children_in_tx(actor, reachable, id),
         do: {:ok, %{children: Enum.map(children, &summary/1)}}
  end

  defp project(%{page: %{type: :knowledge} = page, content: content}, level) do
    with {:ok, projection} <- Knowledge.project(content.content, page.metadata, level) do
      {:ok,
       Map.new(projection, fn
         {:content, body} -> {:body, body}
         field -> field
       end)}
    end
  end

  defp project(%{page: %{type: :doc}} = detail, "L2") do
    case detail[:content] do
      nil ->
        {:ok, %{body: "", level: "L2", metadata: detail.page.metadata}}

      %{content: xml} ->
        with {:ok, markdown} <- Kernel.vfs_document_export(xml),
             do: {:ok, %{body: markdown, level: "L2", metadata: detail.page.metadata}}
    end
  end

  defp project(detail, level) do
    with {:ok, content} <- body(detail, level),
         do: {:ok, %{body: content, level: level, metadata: detail.page.metadata}}
  end

  defp body(%{content: nil}, _level), do: {:ok, ""}
  defp body(%{content: content}, "L0"), do: {:ok, String.slice(content.plain_text, 0, 400)}
  defp body(%{content: content}, "L1"), do: {:ok, String.slice(content.plain_text, 0, 4000)}
  defp body(%{content: content}, "L2"), do: {:ok, content.content}
  defp body(_detail, _level), do: {:error, :invalid_request}

  defp summary(page),
    do: %{
      id: page.id,
      title: page.title,
      type: page.type,
      summary: Knowledge.summary(page.metadata)
    }

  defp directory_summary(page) do
    summary(page)
    |> Map.merge(%{
      editable: "node_edit" in (page.actions || []),
      has_children: page.aggregates[:has_children] == true
    })
  end
end
