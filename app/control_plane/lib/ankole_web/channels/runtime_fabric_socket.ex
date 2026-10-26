defmodule AnkoleWeb.RuntimeFabricSocket do
  @moduledoc """
  WebSocket entry for Agent Computer Workers.

  One Worker holds one socket. The `worker_id` parameter is the Agent UID of
  the Worker, and the Phoenix auth token (`Sec-WebSocket-Protocol`, never the
  URL) is the random credential that the control plane created for that
  Agent's current generation. `AgentWorkers.authenticate/2` compares its
  digest with the Agent's row, so a credential of one Agent cannot connect as
  another, and a credential of a former generation, or of a stopped,
  draining, or deleted Worker, cannot connect at all.
  """

  use Phoenix.Socket

  alias Ankole.AgentWorkers

  channel "worker", AnkoleWeb.WorkerChannel

  @impl true
  def connect(params, socket, connect_info) do
    with true <- AnkoleWeb.Plugs.RequestHost.worker_allowed?(Map.get(connect_info, :uri)),
         {:ok, worker_id} <- worker_id(params),
         {:ok, tenant_id} <- Ankole.Principals.resolve_tenant(worker_id),
         {:ok, %{generation: generation, tenant_id: tenant_id}} <-
           Ankole.Repo.with_tenant(tenant_id, fn ->
             AgentWorkers.authenticate(worker_id, Map.get(connect_info, :auth_token))
           end) do
      {:ok,
       assign(socket, %{worker_id: worker_id, worker_generation: generation, tenant_id: tenant_id})}
    else
      _error -> :error
    end
  end

  @impl true
  def id(socket), do: "runtime_fabric_worker:" <> socket.assigns.worker_id

  defp worker_id(%{"worker_id" => worker_id}) when is_binary(worker_id) do
    case String.trim(worker_id) do
      "" -> :error
      worker_id -> {:ok, worker_id}
    end
  end

  defp worker_id(_params), do: :error
end
