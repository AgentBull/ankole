defmodule Ankole.SignalsGateway.ActorRuntime.Supervisor do
  @moduledoc """
  Supervision root for control-plane actor-runtime services.

  This supervisor is the failure domain for the actor runtime. It uses
  `:one_for_one`: each child is an independent concern (transport, naming, and
  per-actor controllers), so one crashing does not invalidate the others' state.
  Durable correctness lives in PostgreSQL, not in these processes.
  """

  use Supervisor

  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerWebFetchConfig
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobWorkerConfig
  alias Ankole.SignalsGateway.ActorRuntime.DeadLetterNoticeConfig
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig

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
    :ok = AgentConfig.ensure_registered()
    :ok = WorkerWebFetchConfig.ensure_registered()
    :ok = BackgroundAgentJobWorkerConfig.ensure_registered()
    :ok = DeadLetterNoticeConfig.ensure_registered()
    :ok = Ankole.Security.SSRFFilter.ensure_registered()
    :ok = Ankole.IdentityProviders.Config.ensure_registered()

    # Start every inbound consumer before the socket-owning broker. Domain work
    # runs in the dispatcher, supervised RPC tasks, or per-actor controllers;
    # the broker never calls back into a lane while it owns the ROUTER process.
    children = [
      Ankole.SignalsGateway.ActorRuntime.FileTransferLane,
      {Task.Supervisor, name: Ankole.SignalsGateway.ActorRuntime.InboundTaskSupervisor},
      Ankole.SignalsGateway.ActorRuntime.ActorDirectory,
      Ankole.SignalsGateway.ActorRuntime.SessionSupervisor,
      Ankole.SignalsGateway.ActorRuntime.InboundDispatcher,
      broker_child(opts)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Decides whether the broker boots with a real ZeroMQ ROUTER or stays in
  # local-route-only mode. No endpoint configured (the test default) -> start the
  # broker bare so local route handlers can stand in for workers. An endpoint
  # configured -> hand the broker router opts so it binds the production socket.
  # A malformed config is an operator error at boot, so we crash startup loudly
  # rather than silently come up with no transport.
  defp broker_child(opts) do
    case router_opts(opts) do
      {:ok, nil} ->
        Ankole.SignalsGateway.ActorRuntime.Transport.Broker

      {:ok, router_opts} ->
        {Ankole.SignalsGateway.ActorRuntime.Transport.Broker, router: router_opts}

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

  defp normalize_router_opts(endpoint) when is_binary(endpoint) and endpoint != "" do
    router_opts_with_auth_key(endpoint, [])
  end

  defp normalize_router_opts(opts) when is_list(opts) do
    endpoint = Keyword.get(opts, :endpoint) || Keyword.get(opts, :bind_endpoint)
    opts = Keyword.drop(opts, [:endpoint, :bind_endpoint])

    case endpoint do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        router_opts_with_auth_key(endpoint, opts)

      _value ->
        {:error, :missing_endpoint}
    end
  end

  defp normalize_router_opts(_value), do: {:error, :invalid_router_config}

  # Resolves the worker auth key before the native ROUTER starts. Rust receives
  # only the current in-memory key; AppConfigure remains the durable owner.
  defp router_opts_with_auth_key(endpoint, opts) do
    opts = Keyword.put_new(opts, :worker_auth_key, WorkerAuthKey.ensure!())

    {:ok, Keyword.put(opts, :endpoint, endpoint)}
  end
end
