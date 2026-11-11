defmodule AnkoleWeb.RuntimeFabricSocket do
  @moduledoc """
  WebSocket entry for Agent Computer Workers.

  The `worker_id` parameter is the Agent UID. The Phoenix auth token in
  `Sec-WebSocket-Protocol` identifies a managed generation or a paired device's
  Agent binding. The socket records the verified tenant and optional Runner ID
  before it admits any Worker traffic.
  """

  use Phoenix.Socket

  alias Ankole.AgentWorkers

  channel "worker", AnkoleWeb.WorkerChannel

  @impl true
  def connect(params, socket, connect_info) do
    with true <- AnkoleWeb.Plugs.RequestHost.worker_allowed?(Map.get(connect_info, :uri)),
         {:ok, worker_id} <- worker_id(params),
         {:ok, %{generation: generation, tenant_id: tenant_id} = identity} <-
           authenticate(worker_id, Map.get(connect_info, :auth_token)) do
      {:ok,
       assign(socket, %{
         worker_id: worker_id,
         runner_id: Map.get(identity, :runner_id),
         worker_generation: generation,
         tenant_id: tenant_id
       })}
    else
      _error -> :error
    end
  end

  @impl true
  def id(%{assigns: %{runner_id: runner_id}} = socket) when is_binary(runner_id),
    do:
      "runtime_fabric_runner:#{socket.assigns.tenant_id}:#{socket.assigns.worker_id}:#{runner_id}"

  def id(socket),
    do: "runtime_fabric_worker:#{socket.assigns.tenant_id}:#{socket.assigns.worker_id}"

  defp authenticate(worker_id, token) do
    case AgentWorkers.authenticate(worker_id, token) do
      {:error, :invalid_worker_credential} ->
        AgentWorkers.authenticate_runner_worker(worker_id, token)

      result ->
        result
    end
  end

  defp worker_id(%{"worker_id" => worker_id}) when is_binary(worker_id) do
    case String.trim(worker_id) do
      "" -> :error
      worker_id -> {:ok, worker_id}
    end
  end

  defp worker_id(_params), do: :error
end
