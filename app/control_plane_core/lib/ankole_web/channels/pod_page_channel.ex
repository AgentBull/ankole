defmodule AnkoleWeb.PodPageChannel do
  @moduledoc false
  use AnkoleWeb, :channel
  import AnkoleWeb.PodChannel, only: [allowed?: 1, recheck: 1, revoke: 1]
  alias Ankole.Pod.{Documents, Pages}
  alias Ankole.Pod.Serialization, as: JSON

  @impl true
  def join("page:" <> id, _params, socket) do
    Ankole.Repo.put_tenant_id(socket.assigns.tenant_id)

    with true <- AnkoleWeb.PodSocket.active?(socket.assigns),
         {:ok, detail} <- Pages.get(socket.assigns.uid, id) do
      AnkoleWeb.PodChannel.subscribe(socket)
      Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> id)

      {:ok, JSON.detail_json(detail),
       assign(socket, %{page_id: id, page_type: detail.page.type, revision: detail.page.revision})}
    else
      _ -> {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_in("changes", attrs, socket),
    do:
      reply_with(socket, fn ->
        Documents.apply(socket.assigns.uid, socket.assigns.page_id, attrs)
      end)

  def handle_in("sync", %{"revision" => revision}, socket),
    do:
      reply_with(socket, fn ->
        Documents.since(socket.assigns.uid, socket.assigns.page_id, revision)
      end)

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info(:periodic_access, socket) do
    Process.send_after(self(), :periodic_access, 60_000)
    recheck(socket)
  end

  def handle_info(:recheck_access, socket), do: recheck(socket)

  def handle_info({:page_committed, _id}, socket) do
    if allowed?(socket) do
      case latest(socket) do
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

  defp reply_with(socket, fun) do
    # The domain operation checks the required page permission.
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
  end

  defp json_result(result),
    do: Map.update(result, :changes, [], &Enum.map(&1, fn change -> JSON.change_json(change) end))

  defp latest(%{assigns: %{page_type: :doc}} = socket),
    do: Documents.since(socket.assigns.uid, socket.assigns.page_id, socket.assigns.revision)

  defp latest(socket) do
    with {:ok, page} <- Pages.authorize(socket.assigns.uid, socket.assigns.page_id, "page_view"),
         do: {:ok, %{revision: page.revision, changes: []}}
  end
end
