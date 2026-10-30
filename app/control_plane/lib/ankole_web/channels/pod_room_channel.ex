defmodule AnkoleWeb.PodRoomChannel do
  @moduledoc false
  use AnkoleWeb, :channel
  import AnkoleWeb.PodChannel, only: [allowed?: 1, recheck: 1, revoke: 1, with_tenant: 2]
  alias Ankole.Pod.{Bases, Pages}
  alias Ankole.Repo

  intercept(["broadcast", "presence_diff"])

  @impl true
  def join(topic, _params, socket) do
    Repo.put_tenant_id(socket.assigns.tenant_id)

    with_tenant(socket, fn ->
      opts = if String.starts_with?(topic, "applet:"), do: [trash: false], else: []

      with true <- AnkoleWeb.PodSocket.active?(socket.assigns),
           {:ok, page_id} <- page_id(topic, socket.assigns.actor),
           {:ok, _} <- Pages.authorize(socket.assigns.actor, page_id, "page_view", opts) do
        AnkoleWeb.PodChannel.subscribe(socket)
        Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-room:" <> topic)
        if String.starts_with?(topic, "applet:"), do: send(self(), :track_presence)
        {:ok, assign(socket, %{page_id: page_id, room_topic: topic})}
      else
        _ -> {:error, %{reason: "not_found"}}
      end
    end)
  end

  @impl true
  def handle_in("broadcast", %{"event" => event, "payload" => payload}, socket)
      when is_binary(event) do
    if allowed?(socket) and String.starts_with?(socket.assigns.room_topic, "applet:") and
         byte_size(Torque.encode!(%{event: event, payload: payload})) <= 65_536 do
      broadcast_from!(socket, "broadcast", %{
        event: event,
        payload: payload,
        principal_uid: socket.assigns.uid
      })

      {:reply, :ok, socket}
    else
      {:reply, {:error, %{reason: "forbidden"}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info(:track_presence, socket) do
    {:ok, _} =
      AnkoleWeb.PodPresence.track(socket, socket.assigns.uid, %{
        joined_at: System.system_time(:second)
      })

    handle_out("presence_state", AnkoleWeb.PodPresence.list(socket), socket)
  end

  def handle_info(:periodic_access, socket) do
    Process.send_after(self(), :periodic_access, 60_000)
    recheck(socket)
  end

  def handle_info(:recheck_access, socket), do: recheck(socket)

  def handle_info({:room_event, event, payload}, socket), do: handle_out(event, payload, socket)

  @impl true
  def handle_out(event, payload, socket) do
    if allowed?(socket),
      do:
        (
          push(socket, event, payload)
          {:noreply, socket}
        ),
      else: revoke(socket)
  end

  defp page_id("table:" <> id, uid) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, table} <- Bases.table_access(uid, id, :read),
         do: {:ok, table.page_id},
         else: (_ -> {:error, :not_found})
  end

  defp page_id("applet:" <> rest, _uid) do
    case String.split(rest, ":", parts: 2) do
      [id, room] when byte_size(room) in 1..128 ->
        with {:ok, %{type: :applet}} <- Pages.fetch(id),
             do: {:ok, id},
             else: (_ -> {:error, :not_found})

      _ ->
        {:error, :not_found}
    end
  end
end
