defmodule Ankole.ActorRuntime.Supervisor do
  @moduledoc """
  Supervision root for control-plane actor-runtime services.

  This supervisor is the failure domain for the actor runtime. It uses
  `:one_for_one`: each child is an independent concern (transport, naming,
  per-actor controllers, and several recovery loops), so one crashing does not
  invalidate the others' state. Durable correctness lives in Postgres, not in
  these processes, so a single child restart is always safe to recover from
  cold — the recovery loops below simply re-derive runtime state from the
  ledger on their next tick.
  """

  use Supervisor

  alias Ankole.ActorRuntime.WorkerAuthKey

  @doc """
  Starts actor-runtime services.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    WorkerAuthKey.ensure!()

    runtime_opts = runtime_opts(opts)

    # The transport broker, directory, and dynamic supervisor are the core path:
    # without them no actor turn can be sent or routed. The reconciler,
    # activation manager, watchdog, and outbox dispatcher are repeatable recovery
    # loops — each one re-reads the durable ledger and is idempotent, so tests
    # that want to drive recovery by hand (or isolate one concern) switch them
    # off via opts without breaking the core path.
    children =
      [
        Ankole.ActorRuntime.FileTransferLane,
        broker_child(opts),
        Ankole.ActorRuntime.ActorDirectory,
        Ankole.ActorRuntime.SessionSupervisor
      ]
      |> maybe_add_child(
        reconciler_child(runtime_opts),
        enabled?(runtime_opts, :reconciler, true)
      )
      |> maybe_add_child(
        activation_manager_child(runtime_opts),
        enabled?(runtime_opts, :activation_manager, true)
      )
      |> maybe_add_child(watchdog_child(runtime_opts), enabled?(runtime_opts, :watchdog, true))
      |> maybe_add_child(
        outbox_dispatcher_child(runtime_opts),
        enabled?(runtime_opts, :outbox_dispatcher, true)
      )

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp runtime_opts(opts) do
    Application.get_env(:ankole, :actor_runtime, [])
    |> Keyword.merge(Keyword.get(opts, :runtime, []))
  end

  defp enabled?(opts, key, default) do
    opts
    |> Keyword.get(key, [])
    |> case do
      false -> false
      child_opts when is_list(child_opts) -> Keyword.get(child_opts, :enabled, default)
      _value -> default
    end
  end

  defp maybe_add_child(children, _child, false), do: children
  defp maybe_add_child(children, child, true), do: children ++ [child]

  defp reconciler_child(opts) do
    {Ankole.ActorRuntime.Reconciler, child_opts(opts, :reconciler)}
  end

  defp activation_manager_child(opts) do
    {Ankole.ActorRuntime.ActivationManager, child_opts(opts, :activation_manager)}
  end

  defp watchdog_child(opts) do
    {Ankole.ActorRuntime.Watchdog, child_opts(opts, :watchdog)}
  end

  defp outbox_dispatcher_child(opts) do
    {Ankole.ActorRuntime.OutboxDispatcher, child_opts(opts, :outbox_dispatcher)}
  end

  defp child_opts(opts, key) do
    case Keyword.get(opts, key, []) do
      child_opts when is_list(child_opts) -> Keyword.delete(child_opts, :enabled)
      _value -> []
    end
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
        Ankole.ActorRuntime.Transport.Broker

      {:ok, router_opts} ->
        {Ankole.ActorRuntime.Transport.Broker, router: router_opts}

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
