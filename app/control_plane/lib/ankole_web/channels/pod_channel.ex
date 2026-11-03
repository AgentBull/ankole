defmodule AnkoleWeb.PodChannel do
  @moduledoc false
  import Phoenix.Channel
  alias Ankole.Pod.Pages

  def with_tenant(socket, fun),
    do: Ankole.Repo.with_tenant(socket.assigns.tenant_id, fun)

  def subscribe(socket) do
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-access:" <> socket.assigns.tenant_id)
    Process.send_after(self(), :periodic_access, 60_000)
    :ok
  end

  def allowed?(socket),
    do:
      with_tenant(socket, fn ->
        opts =
          if match?("applet:" <> _, socket.assigns[:room_topic]), do: [trash: false], else: []

        AnkoleWeb.PodSocket.active?(socket.assigns) and run_allowed?(socket) and
          match?(
            {:ok, _},
            Pages.authorize(socket.assigns.actor, socket.assigns.page_id, "node_view", opts)
          )
      end)

  defp run_allowed?(%{assigns: %{room_topic: "run:" <> id}} = socket) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, _} <-
           Ankole.AutomationJobs.get_applet_run(socket.assigns.actor, socket.assigns.page_id, id),
         do: true,
         else: (_ -> false)
  end

  defp run_allowed?(_), do: true

  def recheck(socket) do
    if allowed?(socket) do
      {:noreply, socket}
    else
      revoke(socket)
    end
  end

  def revoke(socket) do
    push(socket, "access_revoked", %{})
    {:stop, :normal, socket}
  end
end
