defmodule Ankole.SignalsGateway.ActorRuntime.Supervisor do
  @moduledoc """
  Supervision root for control-plane actor-runtime services.

  This supervisor is the failure domain for the actor runtime. It uses
  `:one_for_one`: each child is an independent concern (route directory,
  naming, per-actor controllers, and the local-route broker), so one crashing
  does not invalidate the others' state. Durable correctness lives in
  PostgreSQL, not in these processes.
  """

  use Supervisor

  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey

  @doc """
  Starts actor-runtime services.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, tuple()} | :ignore
  def init(opts) do
    WorkerAuthKey.ensure!()

    # Start every inbound consumer before the route exit. Domain work runs in the
    # dispatcher, supervised RPC tasks, or per-actor controllers; neither a
    # Worker Channel nor the ROUTER owner calls back into a lane.
    children = [
      Ankole.SignalsGateway.ActorRuntime.WorkerTracker,
      {Task.Supervisor, name: Ankole.SignalsGateway.ActorRuntime.InboundTaskSupervisor},
      Ankole.SignalsGateway.ActorRuntime.ActorDirectory,
      Ankole.SignalsGateway.ActorRuntime.SessionSupervisor,
      Ankole.SignalsGateway.ActorRuntime.InboundDispatcher,
      route_child(opts)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The ZeroMQ ROUTER exists only while Workers still use it. No bind endpoint
  # configured (the test default) means the Worker Channel is the only
  # transport. A malformed config is an operator error at boot.
  defp route_child(opts) do
    case router_opts(opts) do
      {:ok, nil} ->
        WorkerRoute

      {:ok, router_opts} ->
        {WorkerRoute, router: router_opts}

      {:error, reason} ->
        raise ArgumentError, "invalid actor runtime router config: #{inspect(reason)}"
    end
  end

  defp router_opts(opts) do
    opts
    |> Keyword.get(:router, Application.get_env(:ankole, :actor_runtime_router, []))
    |> normalize_router_opts()
  end

  defp normalize_router_opts(value) when value in [nil, false, []], do: {:ok, nil}

  defp normalize_router_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :bind_endpoint) do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        {:ok, opts |> Keyword.delete(:bind_endpoint) |> Keyword.put(:endpoint, endpoint)}

      _value ->
        {:error, :missing_endpoint}
    end
  end

  defp normalize_router_opts(_value), do: {:error, :invalid_router_config}
end
