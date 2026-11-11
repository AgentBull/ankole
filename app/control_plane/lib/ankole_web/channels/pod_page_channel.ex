defmodule AnkoleWeb.PodPageChannel do
  @moduledoc false
  use AnkoleWeb, :channel
  import AnkoleWeb.PodChannel, only: [allowed?: 1, recheck: 1, revoke: 1, with_tenant: 2]
  alias Ankole.Pod.{Documents, OfficeFiles, Pages}
  alias Ankole.Pod.Serialization, as: JSON

  @selection_bytes 4096

  intercept(["presence_diff"])

  @impl true
  def join("page:" <> id, _params, socket) do
    Ankole.Repo.put_tenant_id(socket.assigns.tenant_id)

    with_tenant(socket, fn ->
      AnkoleWeb.PodChannel.subscribe(socket)
      Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> id)
      Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-node:" <> id)

      with true <- AnkoleWeb.PodSocket.active?(socket.assigns),
           {:ok, detail} <- Pages.get(socket.assigns.actor, id) do
        session = Ankole.Ecto.UUIDv7.autogenerate()
        author = Ankole.ActorRef.from_actor(socket.assigns.actor)
        profile = JSON.author_profiles([author])[author]
        office_kind = OfficeFiles.kind(detail.page)
        if detail.page.type == :doc or not is_nil(office_kind), do: send(self(), :track_presence)

        {:ok, Map.put(JSON.detail_json(detail), :presence_session, session),
         assign(socket, %{
           page_id: id,
           page_type: detail.page.type,
           revision: detail.page.revision,
           office_kind: office_kind,
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

  def handle_in("office:apply", attrs, %{assigns: %{office_kind: kind}} = socket)
      when not is_nil(kind),
      do:
        reply_with(socket, fn ->
          OfficeFiles.apply_op(socket.assigns.actor, socket.assigns.page_id, attrs)
        end)

  def handle_in(
        "office:sync",
        %{"revision" => revision},
        %{assigns: %{office_kind: kind}} = socket
      )
      when not is_nil(kind),
      do:
        reply_with(socket, fn ->
          OfficeFiles.since(socket.assigns.actor, socket.assigns.page_id, revision)
        end)

  def handle_in(
        "office:presence",
        %{"selection" => selection} = params,
        %{assigns: %{office_kind: kind}} = socket
      )
      when not is_nil(kind) and (is_map(selection) or is_nil(selection)) do
    normalized =
      if is_map(selection) and Map.has_key?(params, "editing") and
           not Map.has_key?(selection, "editing"),
         do: Map.put(selection, "editing", params["editing"] == true),
         else: selection

    if byte_size(Torque.encode!(normalized)) <= @selection_bytes do
      with_tenant(socket, fn -> update_office_presence(socket, normalized) end)
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
        {:ok, event, result, updated} ->
          push(updated, event, json_result(updated, result))
          {:noreply, assign(updated, :revision, result.revision)}

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

  # The last editor to leave an Office page wakes compaction, so the file
  # catches up with the log soon after everyone closes the page. Presence
  # still lists this channel's own entry while it terminates.
  @impl true
  def terminate(_reason, %{assigns: %{office_kind: kind}} = socket) when not is_nil(kind) do
    present =
      for {_uid, %{metas: metas}} <- AnkoleWeb.PodPresence.list(socket), meta <- metas, do: meta

    if length(present) <= 1,
      do: with_tenant(socket, fn -> OfficeFiles.compact_now(socket.assigns.page_id) end)

    :ok
  end

  def terminate(_reason, _socket), do: :ok

  # An Office selection names cells, blocks, or slides rather than a document
  # revision, so it stays active across revisions until the editor updates it.
  defp update_office_presence(socket, selection) do
    with true <- AnkoleWeb.PodSocket.active?(socket.assigns),
         {:ok, page} <- Pages.authorize(socket.assigns.actor, socket.assigns.page_id, "node_view") do
      editing =
        office_selection_editing?(selection) and
          match?({:ok, _}, Pages.authorize(socket.assigns.actor, page.id, "node_edit"))

      meta = %{
        socket.assigns.presence_meta
        | selection: selection,
          mode: if(editing, do: "editing", else: "viewing")
      }

      {:ok, _} = AnkoleWeb.PodPresence.update(socket, socket.assigns.uid, meta)
      {:reply, :ok, assign(socket, :presence_meta, meta)}
    else
      _ -> revoke(socket)
    end
  end

  defp office_selection_editing?(nil), do: false

  defp office_selection_editing?(selection) when is_map(selection),
    do: Map.get(selection, "editing", false) == true

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

  defp refresh_presence_access(
         %{assigns: %{page_type: page_type, office_kind: office_kind}} = socket
       )
       when page_type == :doc or not is_nil(office_kind) do
    if allowed?(socket) do
      meta = socket.assigns.presence_meta

      wants_editing? =
        if page_type == :doc,
          do: not is_nil(meta.selection),
          else: office_selection_editing?(meta.selection)

      editing =
        wants_editing? and
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
            {:reply, {:ok, json_result(socket, result)},
             assign(socket, :revision, result.revision)}

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

  defp json_result(%{assigns: %{office_kind: kind}}, result) when not is_nil(kind),
    do:
      Map.update(
        result,
        :changes,
        [],
        &Enum.map(&1, fn entry -> JSON.office_op_json(entry) end)
      )

  defp json_result(_socket, result),
    do: Map.update(result, :changes, [], &Enum.map(&1, fn change -> JSON.change_json(change) end))

  defp latest(%{assigns: %{page_type: :doc}} = socket) do
    with {:ok, result} <-
           Documents.since(socket.assigns.actor, socket.assigns.page_id, socket.assigns.revision),
         do: {:ok, "changes", result, socket}
  end

  defp latest(socket) do
    with {:ok, page} <- Pages.authorize(socket.assigns.actor, socket.assigns.page_id, "node_view") do
      previous_kind = socket.assigns.office_kind
      next_kind = OfficeFiles.kind(page)
      socket = refresh_office_kind(socket, next_kind)

      if not is_nil(next_kind) do
        if previous_kind != next_kind,
          do:
            push(socket, "changes", %{
              revision: page.revision,
              object_id: page.object_id,
              changes: []
            })

        # A replacement that commits between the page read and the log read
        # ends Office editing, so the channel reads the page again.
        case OfficeFiles.since(socket.assigns.actor, page.id, socket.assigns.revision) do
          {:ok, result} -> {:ok, "office:changes", result, socket}
          {:error, :invalid_page_type} -> latest(socket)
          error -> error
        end
      else
        {:ok, "changes", %{revision: page.revision, object_id: page.object_id, changes: []},
         socket}
      end
    end
  end

  defp refresh_office_kind(%{assigns: %{office_kind: current}} = socket, current), do: socket

  defp refresh_office_kind(socket, next_kind) do
    was_tracked? = not is_nil(socket.assigns.office_kind)
    meta = %{socket.assigns.presence_meta | selection: nil, mode: "viewing"}
    socket = assign(socket, office_kind: next_kind, presence_meta: meta)

    cond do
      not was_tracked? and not is_nil(next_kind) ->
        {:ok, _} = AnkoleWeb.PodPresence.track(socket, socket.assigns.uid, meta)
        push(socket, "presence_state", AnkoleWeb.PodPresence.list(socket))

      was_tracked? and not is_nil(next_kind) ->
        {:ok, _} = AnkoleWeb.PodPresence.update(socket, socket.assigns.uid, meta)

      was_tracked? ->
        :ok = AnkoleWeb.PodPresence.untrack(socket, socket.assigns.uid)

      true ->
        :ok
    end

    socket
  end
end
