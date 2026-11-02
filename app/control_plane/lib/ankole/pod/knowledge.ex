defmodule Ankole.Pod.Knowledge do
  @moduledoc "Commits a knowledge page's Markdown-compatible body and properties as one revision."
  require Ash.Query
  alias Ankole.{ActorRef, Kernel, Repo}
  alias Ankole.Files.Access
  alias Ankole.Pod.{PageContent, Pages}
  alias Ankole.Pod.Documents.History

  def write(%Ankole.AuthZ.Actor{} = actor, id, revision, xml, metadata)
      when is_integer(revision) and is_binary(xml) and is_map(metadata) do
    Access.write(
      actor.turn_authority,
      fn ->
        with {:ok, page} <- Pages.lock(id),
             {:ok, _} <- Access.authorize(actor, page, "node_edit") do
          put_in_tx(id, %{xml: xml, metadata: metadata}, actor: actor, base_revision: revision)
        end
      end,
      after_commit: &Pages.committed_page(&1.page)
    )
  end

  def write(_actor, _id, _revision, _xml, _metadata), do: {:error, :invalid_request}

  @doc "Merges a stale VFS edit against its exact historical knowledge revision."
  def merge_vfs_knowledge_in_tx(actor, id, revision, parsed) do
    with {:ok, page} <- Pages.lock(id),
         true <- revision < page.revision,
         {:ok, ancestor} <- History.revision_in_tx(id, revision),
         {:ok, current} <- content(id),
         {:ok, current_info} <- Kernel.page_comment_info(current.content),
         {:ok, edit_info} <- Kernel.page_comment_info(parsed.xml),
         {:ok, merged} <-
           Kernel.vfs_merge_knowledge(
             ancestor.content,
             ancestor.metadata,
             current_info.stripped_xml,
             page.metadata,
             edit_info.stripped_xml,
             parsed.metadata
           ),
         do: put_in_tx(id, merged, actor: actor, base_revision: page.revision),
         else: (
           false -> {:error, :precondition_failed}
           {:error, "conflict"} -> {:error, :precondition_failed}
           error -> error
         )
  end

  @doc "Projects an authorized knowledge page at the requested reading depth."
  def project(_xml, metadata, level) when level in [:l0, "l0", "L0"],
    do: {:ok, %{level: "L0", summary: summary(metadata)}}

  def project(xml, metadata, level) when level in [:l1, "l1", "L1"] do
    with {:ok, content} <- Kernel.knowledge_overview(xml, metadata),
         do: {:ok, %{level: "L1", content: content}}
  end

  def project(xml, metadata, level) when level in [:l2, "l2", "L2"] do
    with {:ok, content} <- Kernel.knowledge_export(xml, metadata),
         do: {:ok, %{level: "L2", content: content, metadata: metadata}}
  end

  def project(_xml, _metadata, _level), do: {:error, :invalid_request}

  @doc "A routing preview; complete business metadata is available in the full page."
  def summary(metadata) do
    case metadata["summary"] || metadata["description"] do
      text when is_binary(text) -> Kernel.truncate_o200k_base_tokens(text, 100)
      _ -> ""
    end
  end

  @doc "Reads canonical content for an already-authorized caller in its transaction."
  def read_in_tx(id) do
    with {:ok, page} <- Pages.fetch(id),
         :ok <- knowledge(page),
         {:ok, content} <- content(id),
         do: {:ok, %{page: page, content: content}}
  end

  @doc "Exports a page for an already-authorized caller. System synchronization fields are excluded."
  def export(id) do
    with {:ok, %{page: page, content: content}} <- read_in_tx(id),
         do: Kernel.knowledge_export(content.content, page.metadata)
  end

  def export(actor, id, nil) do
    with {:ok, %{page: page, content: content}} <- Pages.get(actor, id),
         :ok <- knowledge(page),
         do: Kernel.knowledge_export(content.content, page.metadata)
  end

  def export(actor, id, snapshot_id) do
    with {:ok, page} <- Pages.authorize(actor, id, "node_edit"),
         :ok <- knowledge(page),
         {:ok, %{snapshot: snapshot}} <- History.read(actor, id, snapshot_id),
         do: Kernel.knowledge_export(snapshot.content, snapshot.metadata)
  end

  @doc "Merges system synchronization fields under the caller's page lock without a content revision."
  def sync_upstream_in_tx(id, changes) when is_map(changes) do
    Repo.require_transaction()

    with {:ok, page} <- Pages.fetch(id) do
      Pages.update_properties_in_tx(page, :sync_upstream, %{
        upstream_state: Map.merge(page.upstream_state, changes)
      })
    end
  end

  @doc "Writes in the caller's transaction after the caller locks and authorizes the page."
  def put_in_tx(id, attrs, opts \\ []) do
    Repo.require_transaction()

    with {:ok, page} <- Pages.fetch(id),
         :ok <- knowledge(page),
         :ok <- revision(page, Keyword.get(opts, :base_revision, page.revision)),
         {:ok, parsed} <- Kernel.knowledge_validate(Ankole.Attrs.get(attrs, :xml)),
         {:ok, metadata} <-
           Ankole.Ash.Types.JSONMap.cast_input(Ankole.Attrs.get(attrs, :metadata, %{}), []),
         true <- is_map(metadata),
         {:ok, projection} <- Kernel.vfs_projection(:knowledge, parsed.xml, metadata),
         {:ok, previous} <- content(id) do
      now = DateTime.utc_now(:microsecond)
      author = author(opts, page, previous)

      properties =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.take(["title", "icon", "upstream_state"])
        |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
        |> Map.merge(%{metadata: metadata, updated_at: now})
        |> Map.merge(projection)

      with {:ok, content} <- save_content(id, previous, parsed, author, now),
           {:ok, page} <- Pages.update_properties_in_tx(page, :save_knowledge, properties),
           :ok <-
             History.checkpoint_in_tx(page, content, now, Keyword.get(opts, :reason, :checkpoint)),
           :ok <- Ankole.Brain.Knowledge.page_changed_in_tx(page, content) do
        {:ok, %{page: page, content: content}}
      end
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp content(id),
    do: PageContent |> Ash.Query.filter(page_id == ^id) |> Ankole.Ash.read_one()

  defp save_content(id, nil, parsed, author, now) do
    Ankole.Ash.create(PageContent, :create_in_tx, %{
      page_id: id,
      content: parsed.xml,
      plain_text: parsed.plain_text,
      updated_by: author,
      updated_at: now
    })
  end

  defp save_content(_id, previous, parsed, author, now) do
    Ankole.Ash.update(previous, :replace, %{
      content: parsed.xml,
      plain_text: parsed.plain_text,
      updated_by: author,
      updated_at: now
    })
  end

  defp author(opts, page, previous) do
    case Keyword.get(opts, :actor) do
      %Ankole.AuthZ.Actor{} = actor -> ActorRef.from_actor(actor)
      nil -> Keyword.get(opts, :author) || (previous && previous.updated_by) || page.created_by
    end
  end

  defp revision(%{revision: revision}, revision), do: :ok
  defp revision(page, _revision), do: {:error, {:revision_conflict, page.revision}}
  defp knowledge(%{type: :knowledge}), do: :ok
  defp knowledge(_page), do: {:error, :invalid_page_type}
end
