defmodule AnkoleWeb.PodContentChannel do
  @moduledoc "Publishes authorized directory changes and detects changes in effective access."
  use AnkoleWeb, :channel

  @impl true
  def join("content", _params, socket) do
    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      AnkoleWeb.PodChannel.subscribe(socket)

      Ankole.Repo.with_tenant(socket.assigns.tenant_id, fn ->
        Ankole.Conversations.Events.subscribe_rooms()
      end)

      Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-content:" <> socket.assigns.tenant_id)

      case signature(socket) do
        {:ok, signature} ->
          {:ok, %{},
           assign(socket,
             conversations_timer: nil,
             context_signature: signature,
             access_timer: nil,
             force_access: false
           )}

        _ ->
          {:error, %{reason: "not_found"}}
      end
    else
      {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info(:periodic_access, socket) do
    Process.send_after(self(), :periodic_access, 60_000)
    refresh(socket)
  end

  def handle_info(:recheck_access, socket), do: schedule_access(socket, false)
  def handle_info(:access_changed, socket), do: schedule_access(socket, true)

  def handle_info(:refresh_access, socket) do
    force = socket.assigns.force_access
    refresh(assign(socket, access_timer: nil, force_access: false), force)
  end

  def handle_info({:tree_changed, locations, changed_id, removed}, socket) do
    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      AnkoleWeb.PodChannel.with_tenant(socket, fn ->
        ids = Enum.flat_map(locations, &List.wrap(&1.parent_id))

        with {:ok, entries} <-
               Ankole.Pod.Pages.navigation_entries(socket.assigns.actor, [changed_id | ids]) do
          parents = Enum.filter(entries, &(&1.id in ids))
          changed = Enum.find(entries, &(&1.id == changed_id))
          visible_ids = MapSet.new(parents, & &1.id)

          visible =
            Enum.flat_map(locations, fn location ->
              cond do
                location.parent_id && MapSet.member?(visible_ids, location.parent_id) ->
                  [%{parent_id: location.parent_id}]

                is_nil(location.parent_id) and is_nil(location.private_owner_uid) ->
                  [%{parent_id: nil, scope: "space"}]

                is_nil(location.parent_id) and location.private_owner_uid == socket.assigns.uid ->
                  [%{parent_id: nil, scope: "private"}]

                true ->
                  []
              end
            end)

          if visible != [],
            do:
              push(socket, "tree_changed", %{
                directories: visible,
                page_id: changed && changed.id,
                removed: removed,
                parents:
                  Enum.map(
                    parents,
                    &%{
                      id: &1.id,
                      has_children: &1.aggregates.has_children,
                      child_count: &1.aggregates.child_count
                    }
                  )
              })
        end
      end)

      {:noreply, socket}
    else
      AnkoleWeb.PodChannel.revoke(socket)
    end
  end

  def handle_info({:page_updated, id}, socket) do
    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      AnkoleWeb.PodChannel.with_tenant(socket, fn ->
        case Ankole.Pod.Pages.authorize(socket.assigns.actor, id, "node_view") do
          {:ok, page} ->
            push(socket, "page_updated", Map.take(page, [:id, :title, :icon, :children_view]))

          _ ->
            :ok
        end
      end)

      {:noreply, socket}
    else
      AnkoleWeb.PodChannel.revoke(socket)
    end
  end

  def handle_info({:pod_conversations_changed}, socket) do
    timer =
      socket.assigns.conversations_timer ||
        Process.send_after(self(), :conversations_changed, 1_500)

    {:noreply, assign(socket, :conversations_timer, timer)}
  end

  def handle_info(:conversations_changed, socket) do
    socket = assign(socket, :conversations_timer, nil)

    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      push(socket, "conversations_changed", %{})
      {:noreply, socket}
    else
      AnkoleWeb.PodChannel.revoke(socket)
    end
  end

  defp refresh(socket, force \\ false) do
    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      case signature(socket) do
        {:ok, signature} ->
          if force or signature != socket.assigns.context_signature,
            do: push(socket, "access_changed", %{})

          {:noreply, assign(socket, :context_signature, signature)}

        _ ->
          AnkoleWeb.PodChannel.revoke(socket)
      end
    else
      AnkoleWeb.PodChannel.revoke(socket)
    end
  end

  defp schedule_access(socket, force) do
    timer = socket.assigns.access_timer || Process.send_after(self(), :refresh_access, 25)

    {:noreply,
     assign(socket, access_timer: timer, force_access: force or socket.assigns.force_access)}
  end

  defp signature(socket) do
    AnkoleWeb.PodChannel.with_tenant(socket, fn ->
      Ankole.Repo.transact_repeatable_read_only(fn ->
        Ankole.Files.Access.Graph.context_signature(socket.assigns.actor)
      end)
    end)
  end
end
