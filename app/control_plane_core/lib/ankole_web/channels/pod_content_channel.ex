defmodule AnkoleWeb.PodContentChannel do
  @moduledoc "Notifies an authenticated Pod tab to refresh its content snapshot."
  use AnkoleWeb, :channel

  @impl true
  def join("content", _params, socket) do
    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      AnkoleWeb.PodChannel.subscribe(socket)

      Ankole.Repo.with_tenant(socket.assigns.tenant_id, fn ->
        Ankole.Conversations.Events.subscribe_rooms()
      end)

      send(self(), :after_join)
      {:ok, %{}, assign(socket, :conversations_timer, nil)}
    else
      {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info(:periodic_access, socket) do
    Process.send_after(self(), :periodic_access, 60_000)
    refresh(socket)
  end

  def handle_info(event, socket) when event in [:after_join, :recheck_access], do: refresh(socket)

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

  defp refresh(socket) do
    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      push(socket, "changed", %{})
      {:noreply, socket}
    else
      AnkoleWeb.PodChannel.revoke(socket)
    end
  end
end
