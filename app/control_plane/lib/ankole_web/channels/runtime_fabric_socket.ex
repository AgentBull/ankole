defmodule AnkoleWeb.RuntimeFabricSocket do
  @moduledoc """
  WebSocket entry for Agent Computer Workers.

  One Worker holds one socket. The global RuntimeFabric worker key travels as
  the Phoenix auth token (`Sec-WebSocket-Protocol`), never in the URL, and is
  checked here before any channel exists. The `worker_id` parameter is the
  operator-chosen Worker slot; it is public and only binds the socket to one
  Worker Channel topic.
  """

  use Phoenix.Socket

  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey

  channel "worker/installation/*", AnkoleWeb.WorkerChannel

  @impl true
  def connect(params, socket, connect_info) do
    with {:ok, worker_id} <- worker_id(params),
         :ok <- authenticate(Map.get(connect_info, :auth_token)) do
      {:ok, assign(socket, :worker_id, worker_id)}
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

  defp authenticate(token) when is_binary(token) and token != "" do
    if Plug.Crypto.secure_compare(token, WorkerAuthKey.ensure!()), do: :ok, else: :error
  end

  defp authenticate(_token), do: :error
end
