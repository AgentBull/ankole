defmodule Ankole.Pod.AgentPages do
  @moduledoc "Page reads and explicit edits within an Agent conversation's disclosure boundary."
  require Ash.Query
  alias Ankole.{AuthZ, Kernel, Repo}
  alias Ankole.Brain.Access, as: KnowledgeAccess
  alias Ankole.Pod.Access
  alias Ankole.Pod.{Knowledge, Page, Pages}
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

  def children(actor, context, nil) do
    with {:ok, reachable} <- KnowledgeAccess.visibility(context),
         {:ok, directory} <-
           Ankole.Pod.Pages.Queries.list_children(actor, nil, %{reachable: reachable}),
         do: {:ok, Enum.map(directory.pages, &summary/1)}
  end

  def children(actor, context, id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.fetch(id),
           {:ok, reachable} <- visible(context, page),
           {:ok, children} <- children_in_tx(actor, reachable, id),
           do: {:ok, Enum.map(children, &summary/1)}
    end)
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
         do: Knowledge.put_in_tx(id, parsed, actor: actor, base_revision: base_revision)
  end

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
           Pages.create_in_tx(actor, %{
             type: :knowledge,
             parent_id: parent_id,
             title: title,
             xml: parsed.xml,
             metadata: parsed.metadata
           })
  end

  @doc "Requires page visibility for every recipient and edit rights for the Agent and requester."
  def editable(actor, context, page),
    do: authorize_change(actor, context, page, "node_edit")

  def authorize_change(actor, context, page, action, opts \\ []) do
    with {:ok, _} <- visible(context, page, opts),
         {:ok, _} <- Access.authorize(actor, page, action, opts),
         :ok <- requester_authorize(context, page, action, opts),
         do: :ok
  end

  @doc "Applies the conversation boundary to every Brain node, including file attachments."
  def authorize_brain_turn(%AuthZ.Actor{turn_authority: {ref, _}} = actor, page, action, opts)
      when (is_struct(ref, Ankole.Sessions.RunRef) or is_struct(ref, Ankole.Sessions.JobTurnRef)) and
             page.type in [:knowledge, :file] do
    with {:ok, root} <- Pages.Tree.root(page.id) do
      if root.system_key == "ankole_brain" do
        with {:ok, context} <-
               Ankole.Brain.RequestContext.build(actor.principal.uid, %{
                 "signal_id" => ref.signal_id
               }),
             {:ok, _} <- visible(context, page, opts),
             :ok <-
               requester_authorize(
                 %{context | authn: actor.authn},
                 page,
                 Keyword.get(opts, :requester_action, action),
                 opts
               ),
             do: :ok
      else
        :ok
      end
    end
  end

  def authorize_brain_turn(_actor, _page, _action, _opts), do: :ok

  defp requester_authorize(%{disclosure: %{asker_uid: uid}} = context, page, action, opts)
       when is_binary(uid) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid),
         {:ok, _} <-
           Access.authorize(
             AuthZ.Actor.new(principal, authn: Map.get(context, :authn, %{})),
             page,
             action,
             opts
           ),
         do: :ok
  end

  defp requester_authorize(_context, _page, _action, _opts), do: :ok

  def visible(context, page, opts \\ []) do
    trash = Keyword.get(opts, :trash, false)
    graph_opts = if trash, do: [trash_page_ids: [page.id]], else: []

    with {:ok, reachable} <- KnowledgeAccess.visibility(context, graph_opts),
         {:ok, _} <- Access.authorize_reachable(page, "node_view", reachable, trash: trash),
         do: {:ok, reachable},
         else: (_ -> {:error, :not_found})
  end

  defp children_in_tx(actor, reachable, id) do
    Page
    |> Ash.Query.filter(parent_id == ^id)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> PageAnchorFilter.apply_policy(actor, PageAnchorFilter.policy(reachable))
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
end
