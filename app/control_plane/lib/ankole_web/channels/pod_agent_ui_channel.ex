defmodule AnkoleWeb.PodAgentUIChannel do
  @moduledoc """
  Carries an Agent's operations on the Pod page to the signed-in Human's tabs,
  and their answers back. Every Pod tab joins `agent_ui` once. The tab that
  claims a request first runs it on its page with the ui-sdk agent bridge.
  """

  use AnkoleWeb, :channel
  alias Ankole.Pod.AgentUI

  # A tab that joins late still receives the requests that wait for a tab, up to the claim window.
  @replay_ms 20_000
  # An answer above this size cannot fit the Agent's tool result anyway.
  @max_result_bytes 512_000

  @impl true
  def join("agent_ui", _params, socket) do
    Ankole.Repo.put_tenant_id(socket.assigns.tenant_id)

    if AnkoleWeb.PodSocket.active?(socket.assigns) do
      Phoenix.PubSub.subscribe(
        Ankole.PubSub,
        AgentUI.topic(socket.assigns.tenant_id, socket.assigns.uid)
      )

      AnkoleWeb.PodChannel.subscribe(socket)
      send(self(), :replay)
      {:ok, socket}
    else
      {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_in("claim", %{"id" => id}, socket) when is_binary(id) do
    case with_tenant(socket, fn -> AgentUI.claim(socket.assigns.uid, id) end) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("result", %{"id" => id} = params, socket) when is_binary(id) do
    answer =
      case params do
        %{"error" => error} when is_binary(error) ->
          %{status: :failed, error: String.slice(error, 0, 4_000)}

        %{"result" => result} ->
          if byte_size(Ankole.JSON.encode!(result)) <= @max_result_bytes,
            do: %{status: :done, result: result},
            else: %{status: :failed, error: "The page answered with more than 512 KB."}

        _other ->
          nil
      end

    with %{} <- answer,
         :ok <- with_tenant(socket, fn -> AgentUI.answer(socket.assigns.uid, id, answer) end) do
      {:reply, :ok, socket}
    else
      _ -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{reason: "invalid_request"}}, socket}

  @impl true
  def handle_info({:agent_ui_request, id}, socket) do
    with_tenant(socket, fn ->
      case AgentUI.pending_one(socket.assigns.uid, id) do
        {:ok, %{} = request} -> push_request(socket, request)
        _gone -> :ok
      end
    end)

    {:noreply, socket}
  end

  def handle_info(:replay, socket) do
    since = DateTime.add(DateTime.utc_now(:microsecond), -@replay_ms, :millisecond)

    with_tenant(socket, fn ->
      socket.assigns.uid |> AgentUI.pending(since) |> Enum.each(&push_request(socket, &1))
    end)

    {:noreply, socket}
  end

  def handle_info(:periodic_access, socket) do
    Process.send_after(self(), :periodic_access, 60_000)
    recheck(socket)
  end

  def handle_info(:recheck_access, socket), do: recheck(socket)

  defp recheck(socket) do
    if AnkoleWeb.PodSocket.active?(socket.assigns),
      do: {:noreply, socket},
      else: AnkoleWeb.PodChannel.revoke(socket)
  end

  defp push_request(socket, request) do
    agent =
      case Ankole.Principals.get_principal(request.agent_uid) do
        # The name the person sees in chat, such as "Ada's assistant" for a personal assistant.
        {:ok, principal} -> Ankole.Principals.Agents.display_name(principal)
        _missing -> request.agent_uid
      end

    push(socket, "request", %{
      id: request.id,
      operation: Atom.to_string(request.operation),
      arguments: request.arguments,
      agent: %{uid: request.agent_uid, name: agent}
    })
  end

  defp with_tenant(socket, fun), do: Ankole.Repo.with_tenant(socket.assigns.tenant_id, fun)
end
