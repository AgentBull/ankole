defmodule AnkoleWeb.PodPageChannel do
  @moduledoc false
  use AnkoleWeb, :channel
  import AnkoleWeb.PodChannel, only: [allowed?: 1, recheck: 1, revoke: 1, with_tenant: 2]
  alias Ankole.Pod.{Documents, Pages}
  alias Ankole.Pod.Serialization, as: JSON

  intercept(["presence_diff"])

  @impl true
  def join("page:" <> id, _params, socket) do
    Ankole.Repo.put_tenant_id(socket.assigns.tenant_id)

    with_tenant(socket, fn ->
      with true <- AnkoleWeb.PodSocket.active?(socket.assigns),
           {:ok, detail} <- Pages.get(socket.assigns.actor, id) do
        AnkoleWeb.PodChannel.subscribe(socket)
        Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> id)
        Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-node:" <> id)

        session = Ankole.Ecto.UUIDv7.autogenerate()
        author = Ankole.ActorRef.from_actor(socket.assigns.actor)
        profile = JSON.author_profiles([author])[author]
        if detail.page.type == :doc, do: send(self(), :track_presence)

        {:ok, Map.put(JSON.detail_json(detail), :presence_session, session),
         assign(socket, %{
           page_id: id,
           page_type: detail.page.type,
           revision: detail.page.revision,
           presence_meta:
             Map.merge(profile, %{session_id: session, selection: nil, mode: "viewing"})
         })}
      else
        _ -> {:error, %{reason: "not_found"}}
      end
    end)
  end

  @impl true
  def handle_in("changes", attrs, socket),
    do:
      reply_with(socket, fn ->
        Documents.apply(socket.assigns.actor, socket.assigns.page_id, attrs)
      end)

  def handle_in("sync", %{"revision" => revision}, socket),
    do:
      reply_with(socket, fn ->
        Documents.since(socket.assigns.actor, socket.assigns.page_id, revision)
      end)

  def handle_in("presence", %{"selection" => selection}, %{assigns: %{page_type: :doc}} = socket) do
    if valid_selection?(selection) do
      with_tenant(socket, fn -> update_presence(socket, selection) end)
    else
      {:reply, {:error, %{reason: "invalid_request"}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info(:track_presence, socket) do
    if allowed?(socket) do
      {:ok, _} =
        AnkoleWeb.PodPresence.track(socket, socket.assigns.uid, socket.assigns.presence_meta)

      handle_out("presence_state", AnkoleWeb.PodPresence.list(socket), socket)
    else
      revoke(socket)
    end
  end

  def handle_info(:periodic_access, socket) do
    Process.send_after(self(), :periodic_access, 60_000)
    refresh_presence_access(socket)
  end

  def handle_info(:recheck_access, socket), do: refresh_presence_access(socket)

  def handle_info({:comments_read, uid}, socket) do
    if uid == Ankole.AuthZ.Actor.uid(socket.assigns.actor) do
      handle_info({:comments_committed, socket.assigns.page_id}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comments_committed, _id}, socket) do
    if allowed?(socket) do
      push(socket, "comments_changed", %{})
      {:noreply, socket}
    else
      revoke(socket)
    end
  end

  def handle_info({:node_committed, _id}, socket) do
    if allowed?(socket) do
      case with_tenant(socket, fn -> latest(socket) end) do
        {:ok, result} ->
          push(socket, "changes", json_result(result))
          {:noreply, assign(socket, :revision, result.revision)}

        _ ->
          {:stop, :normal, socket}
      end
    else
      revoke(socket)
    end
  end

  @impl true
  def handle_out(event, payload, socket) do
    if allowed?(socket) do
      push(socket, event, payload)
      {:noreply, socket}
    else
      revoke(socket)
    end
  end

  defp update_presence(socket, selection) do
    with true <- AnkoleWeb.PodSocket.active?(socket.assigns),
         {:ok, page} <- Pages.authorize(socket.assigns.actor, socket.assigns.page_id, "node_view") do
      if is_nil(selection) or selection["revision"] == page.revision do
        editing =
          not is_nil(selection) and
            match?({:ok, _}, Pages.authorize(socket.assigns.actor, page.id, "node_edit"))

        meta = %{
          socket.assigns.presence_meta
          | selection: selection,
            mode: if(editing, do: "editing", else: "viewing")
        }

        {:ok, _} = AnkoleWeb.PodPresence.update(socket, socket.assigns.uid, meta)
        {:reply, :ok, assign(socket, :presence_meta, meta)}
      else
        {:reply, {:ok, %{stale: true}}, socket}
      end
    else
      _ -> revoke(socket)
    end
  end

  defp refresh_presence_access(%{assigns: %{page_type: :doc}} = socket) do
    if allowed?(socket) do
      meta = socket.assigns.presence_meta

      editing =
        not is_nil(meta.selection) and
          with_tenant(socket, fn ->
            match?(
              {:ok, _},
              Pages.authorize(socket.assigns.actor, socket.assigns.page_id, "node_edit")
            )
          end)

      updated = %{meta | mode: if(editing, do: "editing", else: "viewing")}
      if updated != meta, do: AnkoleWeb.PodPresence.update(socket, socket.assigns.uid, updated)
      {:noreply, assign(socket, :presence_meta, updated)}
    else
      revoke(socket)
    end
  end

  defp refresh_presence_access(socket), do: recheck(socket)

  defp valid_selection?(nil), do: true

  defp valid_selection?(
         %{"revision" => revision, "anchor" => anchor, "head" => head} = selection
       ),
       do:
         map_size(selection) == 3 and is_integer(revision) and revision >= 0 and
           is_integer(anchor) and anchor in 0..8_388_608 and is_integer(head) and
           head in 0..8_388_608

  defp valid_selection?(_), do: false

  defp reply_with(socket, fun) do
    with_tenant(socket, fn ->
      if AnkoleWeb.PodSocket.active?(socket.assigns) do
        case fun.() do
          {:ok, result} ->
            {:reply, {:ok, json_result(result)}, assign(socket, :revision, result.revision)}

          {:error, reason} ->
            if allowed?(socket) do
              error = JSON.error(reason)

              {:reply, {:error, %{reason: error.code, details: JSON.json_value(error.details)}},
               socket}
            else
              revoke(socket)
            end
        end
      else
        revoke(socket)
      end
    end)
  end

  defp json_result(result),
    do: Map.update(result, :changes, [], &Enum.map(&1, fn change -> JSON.change_json(change) end))

  defp latest(%{assigns: %{page_type: :doc}} = socket),
    do: Documents.since(socket.assigns.actor, socket.assigns.page_id, socket.assigns.revision)

  defp latest(socket) do
    with {:ok, page} <- Pages.authorize(socket.assigns.actor, socket.assigns.page_id, "node_view"),
         do: {:ok, %{revision: page.revision, object_id: page.object_id, changes: []}}
  end
end
