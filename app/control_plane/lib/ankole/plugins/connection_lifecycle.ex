defmodule Ankole.Plugins.ConnectionLifecycle do
  @moduledoc """
  Keeps one plugin's long connections equal to its enabled bindings across the cluster.

  A plugin declares its connection set with
  `use Ankole.Plugins.ConnectionLifecycle` and implements the callbacks of this
  module. This module owns the periodic reconcile process, the merge of binding
  and identity-provider specs by connection key, cluster-wide single-owner
  coordination across connected Erlang nodes, and restart attempts for each
  supervised connection process. The plugin owns its config, its consumers, and
  its client protocol. Each node's connection Registry retains the last
  successful start arguments so a standby or restarted reconciler can resume a
  live connection even when the current binding snapshot is blocked.

  Across a multi-replica control-plane deployment, at most one replica holds a
  given `(adapter, connection_key)` owner at a time via `:global` locking and
  registration. Peer replicas monitor the active owner and fail over immediately
  when the owning node enters graceful HTTP drain or disconnects.

  Each owner registers under its connection key with `registry_value/2` of the
  config and consumers it serves. When the desired value differs, for example
  after a rotated secret or a changed consumer set, the owner is replaced on
  whichever replica currently holds it.

  `binding_spec/2` must be pure: it reads stored configuration and returns a
  spec without provider calls. Runtime identity and other provider lookups
  belong to the owner start in `owner_child_spec/3`, behind an adapter-owned
  cache. The pass runs every minute for every enabled binding.

  A blocked, error, or owner start reason may be `%{reason: term(), retry_at:
  DateTime.t()}`. The pass reports `retry_at` next to the reason and leaves it
  out of the error identity, so a moving retry time is the same error.

  An error set that stays equal between passes is logged once as a warning,
  then at most once every ten minutes at info level with the repeat count.
  A changed error set is a new warning; an empty set after errors is logged at
  info level.

  The `use` options are `:adapter` (the binding adapter id), `:registry` and
  `:supervisor` (the plugin's owner Registry and DynamicSupervisor), and the
  optional `:interval_ms` (default 60 seconds), `:conflict_reason` (default
  `:conflicting_app_secret`), and `:restart_backoff_ms` (default 0, 5 seconds,
  then 30 seconds).
  """

  use GenServer

  alias Ankole.IdentityProviders
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.Signals.Binding

  @call_timeout 30_000
  @peer_probe_timeout 5_000
  @connection_specs_key {__MODULE__, :connection_specs}
  @reconciler_pid_key {__MODULE__, :reconciler_pid}
  @repeat_log_interval_ms :timer.minutes(10)

  @typedoc "One desired connection: the config it uses and the consumers it serves."
  @type spec :: %{
          required(:config) => map(),
          required(:consumers) => [map()],
          optional(:secret_fingerprint) => term()
        }

  @doc "Builds the desired connection of one enabled binding."
  @callback binding_spec(Binding.t(), opts :: keyword()) ::
              {:ok, spec()}
              | {:blocked, connection_key :: term(), reason :: term()}
              | {:error, term()}

  @doc "Builds the desired connection of one active identity provider."
  @callback identity_spec(provider :: map()) :: {:ok, spec()} | :skip | {:error, term()}

  @doc "Builds desired event connections owned by active connector credentials."
  @callback connector_specs() :: {:ok, [spec()]} | {:error, term()}

  @doc "Returns the registry key of the owner that serves this config and consumer list."
  @callback connection_key(config :: map(), consumers :: [map()]) :: term()

  @doc "Returns the child spec that starts the owner of one connection."
  @callback owner_child_spec(key :: term(), config :: map(), consumers :: [map()]) ::
              Supervisor.child_spec() | {module(), term()}

  @optional_callbacks identity_spec: 1, connector_specs: 0

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Ankole.Plugins.ConnectionLifecycle

      @connection_lifecycle %{
        adapter: Keyword.fetch!(opts, :adapter),
        registry: Keyword.fetch!(opts, :registry),
        supervisor: Keyword.fetch!(opts, :supervisor),
        cluster_scope: Keyword.get(opts, :cluster_scope, __MODULE__),
        cluster_members: Keyword.get(opts, :cluster_members, [__MODULE__]),
        drain_state_key: Keyword.get(opts, :drain_state_key, {AnkoleWeb.EndpointDrain, :state}),
        interval_ms: Keyword.get(opts, :interval_ms, 60_000),
        conflict_reason: Keyword.get(opts, :conflict_reason, :conflicting_app_secret),
        restart_backoff_ms: Keyword.get(opts, :restart_backoff_ms, [0, 5_000, 30_000])
      }

      @doc false
      def __connection_lifecycle__, do: @connection_lifecycle

      @doc false
      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
      end

      @doc "Starts the periodic connection reconciler."
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []),
        do: Ankole.Plugins.ConnectionLifecycle.start_link(__MODULE__, opts)

      @doc "Reconciles immediately through the running reconciler."
      @spec reconcile(GenServer.server()) :: map()
      def reconcile(server \\ __MODULE__),
        do: Ankole.Plugins.ConnectionLifecycle.reconcile(server)

      @doc "Requests a reconciliation without waiting for it."
      @spec reconcile_async(GenServer.server()) :: :ok
      def reconcile_async(server \\ __MODULE__),
        do: Ankole.Plugins.ConnectionLifecycle.reconcile_async(server)

      @doc "Reconciles enabled bindings once in the calling process."
      @spec reconcile_once(keyword()) :: map()
      def reconcile_once(opts \\ []),
        do: Ankole.Plugins.ConnectionLifecycle.reconcile_once(__MODULE__, opts)

      @doc "Stops the owner registered under a connection key across the cluster, if any."
      @spec stop(term()) :: :ok | {:error, term()}
      def stop(key), do: Ankole.Plugins.ConnectionLifecycle.stop(__MODULE__, key)

      @doc "Lists the connection keys of the owners running in this node."
      @spec registered_keys() :: [term()]
      def registered_keys, do: Ankole.Plugins.ConnectionLifecycle.registered_keys(__MODULE__)
    end
  end

  @doc "Keeps a plugin's connection registry, owners and reconciler in one restart group."
  def supervisor_spec(plugin, children) do
    %{
      id: plugin,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
      type: :supervisor
    }
  end

  @doc false
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) when is_atom(module) and is_list(opts) do
    state = %{
      module: module,
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(
            :ankole,
            :signal_connection_reconcile_interval_ms,
            module.__connection_lifecycle__().interval_ms
          )
        ),
      reconcile_opts: Keyword.drop(opts, [:name, :interval_ms, :restart_backoff_ms]),
      restart_backoff_ms:
        Keyword.get(
          opts,
          :restart_backoff_ms,
          module.__connection_lifecycle__().restart_backoff_ms
        ),
      monitors: %{},
      failures: %{},
      retry_timers: %{},
      failover_scheduled?: false,
      alert: nil
    }

    GenServer.start_link(__MODULE__, state, name: Keyword.get(opts, :name, module))
  end

  @doc false
  @spec reconcile(GenServer.server()) :: map()
  def reconcile(server), do: GenServer.call(server, :reconcile, @call_timeout)

  @doc false
  @spec reconcile_async(GenServer.server()) :: :ok
  def reconcile_async(server) when is_atom(server) do
    if Node.list() == [] do
      GenServer.cast(server, :reconcile)
    else
      GenServer.abcast([node() | Node.list()], server, :reconcile)
      :ok
    end
  end

  def reconcile_async(server), do: GenServer.cast(server, :reconcile)

  @doc false
  @spec reconcile_once(module(), keyword()) :: map()
  def reconcile_once(module, opts) when is_atom(module) and is_list(opts) do
    module |> reconcile_connections(opts) |> Map.drop([:connections, :blocked_keys])
  end

  defp reconcile_connections(module, opts) do
    config = module.__connection_lifecycle__()

    {specs, errors} =
      Ankole.Tenants.list()
      |> Enum.reduce({%{}, []}, fn tenant, acc ->
        Repo.with_tenant(tenant.id, fn ->
          snapshot_tenant_connections(module, config, tenant.id, acc, opts)
        end)
      end)

    stopped = stop_undesired(module, specs, errors)
    blocked_keys = MapSet.new(for %{blocked_connection_key: key} <- errors, do: key)

    outcomes =
      specs
      # A blocked binding can share its key with an identity provider. Starting
      # that partial spec would replace the live connection without the chat
      # consumer of the blocked binding.
      |> Enum.reject(fn {key, _spec} -> MapSet.member?(blocked_keys, key) end)
      |> Enum.map(fn {key, spec} ->
        {key, tenant_id!(spec.consumers),
         ensure_owner_started(module, key, spec.config, Enum.reverse(spec.consumers))}
      end)

    started =
      for {key, tenant_id, {:ok, pid, locality}} <- outcomes,
          do: {key, tenant_id, pid, locality}

    failed = for {key, tenant_id, {:error, reason}} <- outcomes, do: {key, tenant_id, reason}

    %{
      connections:
        Map.new(started, fn {key, _tenant_id, pid, locality} -> {key, {pid, locality}} end),
      blocked_keys: MapSet.to_list(blocked_keys),
      started: length(started),
      stopped: stopped,
      errors:
        Enum.reverse(errors) ++
          Enum.map(failed, fn {_key, tenant_id, reason} ->
            put_reason(%{tenant_id: tenant_id}, reason)
          end)
    }
  end

  defp snapshot_tenant_connections(module, config, tenant_id, acc, opts) do
    config.adapter
    |> Ankole.Signals.Bindings.list_enabled_bindings()
    |> Enum.reduce(acc, &add_binding(module, config, &1, &2, opts))
    |> add_identity_providers(module, config)
    |> add_connector_specs(module, config)
  rescue
    error ->
      Logging.warning(
        "plugins.connection_snapshot_failed",
        "Plugin connection snapshot failed",
        Map.merge(Logging.failure_fields(:error, error, __STACKTRACE__), %{
          tenant_id: tenant_id,
          adapter: config.adapter
        })
      )

      {specs, errors} = acc

      {specs,
       [
         %{tenant_id: tenant_id, reason: {:snapshot_failed, Exception.message(error)}}
         | errors
       ]}
  end

  @doc false
  @spec stop(module(), term()) :: :ok | {:error, term()}
  def stop(module, key) do
    %{cluster_scope: cluster_scope, cluster_members: cluster_members} =
      module.__connection_lifecycle__()

    global_name = global_owner_name(cluster_scope, key)

    :global.trans({global_lock_id(cluster_scope, key), self()}, fn ->
      local_result = stop_local(module, key)

      Enum.each(cluster_members -- [module], &forget_connection_spec(&1, key))

      case :global.whereis_name(global_name) do
        pid when is_pid(pid) ->
          :global.unregister_name(global_name)
          stop_on_peer(node(pid), cluster_members, key)

        :undefined ->
          :ok
      end

      Enum.each(Node.list(), fn peer ->
        :erpc.cast(peer, __MODULE__, :forget_peer_connection_spec, [cluster_members, key])
      end)

      local_result
    end)
  end

  # Owners are the children of the dynamic supervisor. Other processes can
  # register in the same registry, such as the WeCom bot client, and are not
  # connections.
  @doc false
  @spec registered_keys(module()) :: [term()]
  def registered_keys(module) do
    %{registry: registry, supervisor: supervisor} = module.__connection_lifecycle__()

    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> Registry.keys(registry, pid)
      _restarting -> []
    end)
    |> Enum.sort()
  end

  @impl true
  def init(state) do
    %{registry: registry} = state.module.__connection_lifecycle__()

    if Process.whereis(registry) do
      Registry.put_meta(registry, @reconciler_pid_key, self())
    end

    Phoenix.PubSub.subscribe(Ankole.PubSub, "connector_credentials")
    Phoenix.PubSub.subscribe(Ankole.PubSub, AnkoleWeb.EndpointDrain.lifecycle_topic())

    if handler = Application.get_env(:ankole, :connection_lifecycle_error_handler) do
      Process.flag(:error_handler, handler)
    end

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    await_cluster_sync()
    {_result, state} = run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    {result, state} = run_reconcile(state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:reconcile, state) do
    {_result, state} = run_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {_result, state} = run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  def handle_info(:failover_reconcile, state) do
    {_result, state} = run_reconcile(%{state | failover_scheduled?: false})
    {:noreply, state}
  end

  def handle_info({:endpoint_draining, drained_state_key, drained_node}, state) do
    if peer_drain_event?(state.module, drained_state_key, drained_node) do
      {:noreply, schedule_failover_reconcile(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:connector_credentials_changed, _tenant_id}, %{interval_ms: nil} = state),
    do: {:noreply, state}

  def handle_info({:connector_credentials_changed, _tenant_id}, state) do
    {_result, state} = run_reconcile(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {%{key: key, pid: monitored_pid, locality: :peer}, monitors} ->
        handle_peer_down(%{state | monitors: monitors}, key, monitored_pid, reason)

      {%{key: key, locality: :local}, monitors} ->
        handle_local_down(%{state | monitors: monitors}, key, reason)
    end
  end

  def handle_info({:restart_key, key}, state) do
    state = %{state | retry_timers: Map.delete(state.retry_timers, key)}

    %{registry: registry, drain_state_key: drain_state_key} =
      state.module.__connection_lifecycle__()

    if AnkoleWeb.EndpointDrain.draining?(drain_state_key) do
      {:noreply, state}
    else
      restart_cached_key(state, registry, key)
    end
  end

  @impl true
  def format_status(%{state: state} = status) do
    %{
      status
      | state:
          Map.take(state, [
            :module,
            :interval_ms,
            :restart_backoff_ms,
            :monitors,
            :failures,
            :alert
          ])
    }
  end

  defp handle_local_down(state, key, reason) do
    %{drain_state_key: drain_state_key} = state.module.__connection_lifecycle__()

    if reason == :shutdown or AnkoleWeb.EndpointDrain.draining?(drain_state_key) do
      {:noreply, %{state | failures: Map.delete(state.failures, key)}}
    else
      {:noreply, retry_key(state, key, reason)}
    end
  end

  defp handle_peer_down(state, key, monitored_pid, reason) do
    state = %{state | failures: Map.delete(state.failures, key)}

    if peer_still_managing?(state.module, node(monitored_pid), reason) do
      {:noreply, state}
    else
      {:noreply, schedule_failover_reconcile(state)}
    end
  end

  defp schedule_failover_reconcile(%{failover_scheduled?: true} = state), do: state

  defp schedule_failover_reconcile(state) do
    send(self(), :failover_reconcile)
    %{state | failover_scheduled?: true}
  end

  defp peer_drain_event?(module, drained_state_key, drained_node) do
    %{drain_state_key: own_drain_key, cluster_members: cluster_members} =
      module.__connection_lifecycle__()

    cond do
      drained_node != node() ->
        drained_state_key == own_drain_key

      drained_state_key == own_drain_key ->
        false

      true ->
        Enum.any?(cluster_members, fn member ->
          member.__connection_lifecycle__().drain_state_key == drained_state_key
        end)
    end
  end

  defp restart_cached_key(state, registry, key) do
    case {Map.fetch(connection_specs(state.module), key), Registry.lookup(registry, key)} do
      {{:ok, {config, consumers}}, []} ->
        case ensure_owner_started(state.module, key, config, consumers) do
          {:ok, pid, locality} ->
            {:noreply, monitor_key(state, key, pid, locality)}

          {:draining, _key} ->
            {:noreply, state}

          {:error, reason} ->
            {:noreply, retry_key(state, key, reason)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp run_reconcile(%{module: module, reconcile_opts: opts} = state) do
    result = reconcile_connections(module, opts)
    state = log_reconcile_errors(state, result.errors)

    %{
      registry: registry,
      supervisor: supervisor,
      cluster_scope: cluster_scope,
      cluster_members: cluster_members
    } = module.__connection_lifecycle__()

    local_live =
      supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          Enum.map(Registry.keys(registry, pid), &{&1, {pid, :local}})

        _restarting ->
          []
      end)
      |> Map.new()

    specs_cache = connection_specs(module)

    peer_live =
      (Map.keys(specs_cache) ++ result.blocked_keys)
      |> Enum.uniq()
      |> Enum.reject(&(Map.has_key?(local_live, &1) or Map.has_key?(result.connections, &1)))
      |> Enum.reduce(%{}, fn key, acc ->
        case active_peer_owner(cluster_scope, cluster_members, key) do
          {:ok, pid, peer_spec} ->
            if peer_spec != nil and not Map.has_key?(specs_cache, key) do
              remember_connection_spec(module, key, peer_spec)
            end

            Map.put(acc, key, {pid, :peer})

          :none ->
            acc
        end
      end)

    specs_cache = connection_specs(module)
    live = Map.merge(peer_live, local_live)

    # The Registry keeps the successful start arguments after a client exits.
    # A standby or restarted reconciler can thus resume a blocked connection
    # when the previous owner or owning node goes away.
    resume_outcomes =
      specs_cache
      |> Enum.reject(fn {key, _spec} ->
        Map.has_key?(live, key) or Map.has_key?(result.connections, key)
      end)
      |> Enum.map(fn {key, {config, consumers}} ->
        {key, tenant_id!(consumers), ensure_owner_started(module, key, config, consumers)}
      end)

    resumed =
      for {key, tenant_id, {:ok, pid, locality}} <- resume_outcomes,
          do: {key, tenant_id, pid, locality}

    failed =
      for {key, tenant_id, {:error, reason}} <- resume_outcomes, do: {key, tenant_id, reason}

    result = %{
      result
      | started: result.started + length(resumed),
        connections:
          Map.merge(
            result.connections,
            Map.new(resumed, fn {key, _tenant_id, pid, locality} -> {key, {pid, locality}} end)
          ),
        errors:
          result.errors ++
            Enum.map(failed, fn {_key, tenant_id, reason} ->
              put_reason(%{tenant_id: tenant_id}, reason)
            end)
    }

    active = Map.merge(result.connections, live)

    {monitors, failures} =
      Enum.reduce(state.monitors, {%{}, state.failures}, fn {ref, %{key: key, pid: pid}},
                                                            {monitors, failures} ->
        case Map.get(active, key) do
          {^pid, locality} ->
            entry = %{key: key, pid: pid, locality: locality}
            {Map.put(monitors, ref, entry), Map.delete(failures, key)}

          _other ->
            Process.demonitor(ref, [:flush])
            {monitors, failures}
        end
      end)

    state = %{
      state
      | monitors: monitors,
        failures: Map.take(failures, Map.keys(connection_specs(module)))
    }

    state =
      Enum.reduce(failed, state, fn {key, _tenant_id, reason}, state ->
        retry_key(state, key, reason)
      end)

    # A client can exit before which_children/1 observes it. Monitor the
    # actual start result too, so its DOWN still reaches the restart owner.
    state =
      Enum.reduce(active, state, fn {key, {pid, locality}}, state ->
        monitor_key(state, key, pid, locality)
      end)

    {Map.drop(result, [:desired, :connections, :blocked_keys]), state}
  end

  # One warning per distinct error set. A repeated set is an info line at most
  # every ten minutes; recovery is an info line.
  defp log_reconcile_errors(%{alert: nil} = state, []), do: state

  defp log_reconcile_errors(%{alert: alert} = state, []) do
    adapter = state.module.__connection_lifecycle__().adapter

    Logging.info(
      "#{adapter}_adapter.connection_reconciliation.recovered",
      "#{adapter} adapter connection reconciliation completed without errors",
      %{repeat_count: alert.repeat_count}
    )

    %{state | alert: nil}
  end

  defp log_reconcile_errors(state, errors) do
    adapter = state.module.__connection_lifecycle__().adapter
    event = "#{adapter}_adapter.connection_reconciliation.completed_with_errors"
    message = "#{adapter} adapter connection reconciliation completed with errors"
    hash = errors |> Enum.map(&Map.delete(&1, :retry_at)) |> Enum.sort() |> :erlang.phash2()
    now = System.monotonic_time(:millisecond)

    case state.alert do
      %{hash: ^hash} = alert ->
        alert = %{alert | repeat_count: alert.repeat_count + 1}

        if now - alert.logged_at >= @repeat_log_interval_ms do
          Logging.info(event, message, %{
            adapter: adapter,
            error_count: length(errors),
            repeat_count: alert.repeat_count
          })

          %{state | alert: %{alert | logged_at: now}}
        else
          %{state | alert: alert}
        end

      _changed ->
        Logging.warning(event, message, %{adapter: adapter, error_count: length(errors)})
        %{state | alert: %{hash: hash, repeat_count: 0, logged_at: now}}
    end
  end

  defp monitor_key(state, key, pid, locality) do
    if Enum.any?(state.monitors, fn {_ref, %{pid: monitored}} -> monitored == pid end) do
      state
    else
      entry = %{key: key, pid: pid, locality: locality}
      %{state | monitors: Map.put(state.monitors, Process.monitor(pid), entry)}
    end
  end

  defp retry_key(state, key, reason) do
    attempt = Map.get(state.failures, key, 0) + 1
    adapter = state.module.__connection_lifecycle__().adapter

    Logging.warning(
      "#{adapter}_adapter.connection.client_exited",
      "#{adapter} adapter connection client exited",
      Map.merge(Logging.failure_fields(:exit, reason, []), %{
        connection_key: inspect(key),
        attempt: attempt
      })
    )

    delay = Enum.at(state.restart_backoff_ms, attempt - 1, List.last(state.restart_backoff_ms))
    if timer = state.retry_timers[key], do: Process.cancel_timer(timer)
    timer = Process.send_after(self(), {:restart_key, key}, delay)

    %{
      state
      | failures: Map.put(state.failures, key, attempt),
        retry_timers: Map.put(state.retry_timers, key, timer)
    }
  end

  defp schedule_next(%{interval_ms: nil} = state), do: state

  defp schedule_next(%{interval_ms: interval_ms} = state) do
    Process.send_after(self(), :reconcile, interval_ms)
    state
  end

  defp add_binding(module, config, %Binding{} = binding, {specs, errors}, opts) do
    error = %{
      tenant_id: binding.tenant_id,
      agent_uid: binding.agent_uid,
      binding_name: binding.name
    }

    case module.binding_spec(binding, opts) do
      {:ok, spec} ->
        merge_spec(
          module,
          specs,
          errors,
          tenant_spec(spec),
          Map.put(error, :reason, config.conflict_reason)
        )

      {:blocked, key, reason} ->
        {specs, [error |> put_reason(reason) |> Map.put(:blocked_connection_key, key) | errors]}

      {:error, reason} ->
        if disabled_configuration?(reason),
          do: {specs, errors},
          else: {specs, [put_reason(error, reason) | errors]}
    end
  end

  defp put_reason(error, %{reason: reason, retry_at: %DateTime{} = retry_at}),
    do: Map.merge(error, %{reason: reason, retry_at: retry_at})

  defp put_reason(error, reason), do: Map.put(error, :reason, reason)

  defp add_identity_providers({specs, errors} = acc, module, config) do
    if function_exported?(module, :identity_spec, 1) do
      case IdentityProviders.list_active_provider_refs(config.adapter) do
        {:ok, providers} ->
          Enum.reduce(providers, acc, &add_identity_provider(module, config, &1, &2))

        {:error, reason} ->
          {specs, [%{tenant_id: Repo.tenant_id!(), provider_id: nil, reason: reason} | errors]}
      end
    else
      acc
    end
  end

  defp add_connector_specs({specs, errors} = acc, module, config) do
    if function_exported?(module, :connector_specs, 0) do
      case module.connector_specs() do
        {:ok, connections} ->
          Enum.reduce(connections, acc, fn spec, {specs, errors} ->
            merge_spec(module, specs, errors, tenant_spec(spec), %{
              tenant_id: Repo.tenant_id!(),
              reason: config.conflict_reason
            })
          end)

        {:error, reason} ->
          {specs, [%{tenant_id: Repo.tenant_id!(), reason: reason} | errors]}
      end
    else
      acc
    end
  end

  defp add_identity_provider(module, config, provider, {specs, errors}) do
    error = %{tenant_id: Repo.tenant_id!(), provider_id: provider["provider_id"]}

    case module.identity_spec(provider) do
      {:ok, spec} ->
        merge_spec(
          module,
          specs,
          errors,
          tenant_spec(spec),
          Map.put(error, :reason, config.conflict_reason)
        )

      :skip ->
        {specs, errors}

      {:error, reason} ->
        if disabled_configuration?(reason),
          do: {specs, errors},
          else: {specs, [Map.put(error, :reason, reason) | errors]}
    end
  end

  defp disabled_configuration?(:connection_disabled), do: true
  defp disabled_configuration?({:storage_error, _scope, _key, :connection_disabled}), do: true
  defp disabled_configuration?(_reason), do: false

  # Bindings and identity providers of one app share a single connection with
  # all their consumers. Two configs that disagree about the app secret are
  # refused instead of letting one config's credentials silently win.
  defp tenant_spec(spec) do
    tenant_id = Repo.tenant_id!()

    Map.update!(
      spec,
      :consumers,
      &Enum.map(&1, fn consumer -> Map.put(consumer, :tenant_id, tenant_id) end)
    )
  end

  @doc "Starts a connection owner for one chat consumer."
  @spec start_owner(module(), atom(), keyword()) :: GenServer.on_start()
  def start_owner(module, registry, opts) do
    key = Keyword.fetch!(opts, :key)
    config = Keyword.fetch!(opts, :config)
    consumers = [Keyword.fetch!(opts, :consumer)]

    GenServer.start_link(module, opts,
      name: {:via, Registry, {registry, key, registry_value(config, consumers)}}
    )
  end

  @doc "The registry value of an owner that serves this config and consumer list."
  @spec registry_value(map(), [map()]) :: {String.t(), binary()}
  def registry_value(config, consumers),
    do:
      {tenant_id!(consumers), :crypto.hash(:sha256, :erlang.term_to_binary({config, consumers}))}

  @doc false
  def tenant_id!(consumers) do
    case consumers |> Enum.map(&Map.fetch!(&1, :tenant_id)) |> Enum.uniq() do
      [tenant_id] -> tenant_id
      _ -> raise ArgumentError, "A platform connection must belong to exactly one tenant"
    end
  end

  defp merge_spec(module, specs, errors, spec, conflict) do
    key = module.connection_key(spec.config, spec.consumers)

    case specs do
      %{^key => existing} ->
        cond do
          tenant_id!(existing.consumers) != tenant_id!(spec.consumers) ->
            error = Map.merge(conflict, %{reason: :connection_tenant_mismatch})

            keep =
              case owner_tenant_id(module, key) do
                {:ok, tenant_id} when tenant_id == hd(spec.consumers).tenant_id -> spec
                _ -> existing
              end

            {Map.put(specs, key, keep), [error | errors]}

          Map.get(existing, :secret_fingerprint) == Map.get(spec, :secret_fingerprint) ->
            {Map.put(specs, key, %{existing | consumers: spec.consumers ++ existing.consumers}),
             errors}

          true ->
            {specs, [conflict | errors]}
        end

      %{} ->
        {Map.put(specs, key, spec), errors}
    end
  end

  # An incomplete snapshot only retains owners of the tenant that failed.
  defp stop_undesired(module, specs, errors) do
    failed_tenants = MapSet.new(errors, &Map.fetch!(&1, :tenant_id))
    %{cluster_scope: cluster_scope} = module.__connection_lifecycle__()

    (registered_keys(module) ++ Map.keys(connection_specs(module)) ++ global_keys(cluster_scope))
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(specs, &1))
    |> Enum.reject(&retain_failed_tenant_key?(module, failed_tenants, &1))
    |> Enum.count(&(stop(module, &1) == :ok))
  end

  defp retain_failed_tenant_key?(module, failed_tenants, key) do
    if MapSet.size(failed_tenants) == 0 do
      false
    else
      retain? =
        case owner_tenant_id(module, key) do
          {:ok, tenant_id} -> MapSet.member?(failed_tenants, tenant_id)
          :error -> false
        end

      retain? and not disabled_connection?(module, key)
    end
  end

  defp owner_tenant_id(module, key) do
    %{
      registry: registry,
      cluster_scope: cluster_scope,
      cluster_members: cluster_members
    } = module.__connection_lifecycle__()

    case Registry.lookup(registry, key) do
      [{_pid, {tenant_id, _fingerprint}}] ->
        {:ok, tenant_id}

      [] ->
        case Map.fetch(connection_specs(module), key) do
          {:ok, {_config, consumers}} ->
            {:ok, tenant_id!(consumers)}

          :error ->
            peer_tenant_id(cluster_scope, cluster_members, key)
        end
    end
  end

  defp peer_tenant_id(cluster_scope, cluster_members, key) do
    case :global.whereis_name(global_owner_name(cluster_scope, key)) do
      pid when is_pid(pid) ->
        try do
          :erpc.call(
            node(pid),
            __MODULE__,
            :lookup_local_tenant_id,
            [cluster_members, key],
            @peer_probe_timeout
          )
        catch
          _, _ -> :error
        end

      :undefined ->
        :error
    end
  end

  @doc false
  def lookup_local_tenant_id(cluster_members, key) when is_list(cluster_members) do
    Enum.find_value(cluster_members, :error, fn module ->
      %{registry: registry} = module.__connection_lifecycle__()

      case Registry.lookup(registry, key) do
        [{_pid, {tenant_id, _fingerprint}}] -> {:ok, tenant_id}
        [] -> nil
      end
    end)
  end

  defp disabled_connection?(module, key) do
    case Map.get(connection_specs(module), key) do
      {%{"authConfigId" => id}, consumers} when is_binary(id) ->
        Repo.with_tenant(tenant_id!(consumers), fn ->
          match?(
            {:ok, %{status: "disabled"}},
            Ankole.Connectors.get_auth_config_for_configuration(id)
          )
        end)

      _ ->
        false
    end
  end

  defp ensure_owner_started(module, key, config, consumers) do
    %{
      cluster_scope: cluster_scope,
      cluster_members: cluster_members,
      drain_state_key: drain_state_key
    } = module.__connection_lifecycle__()

    global_name = global_owner_name(cluster_scope, key)

    :global.trans({global_lock_id(cluster_scope, key), self()}, fn ->
      if AnkoleWeb.EndpointDrain.draining?(drain_state_key) do
        _ = stop_local(module, key)
        {:draining, key}
      else
        coordinate_cluster_owner(
          module,
          global_name,
          cluster_members,
          key,
          config,
          consumers
        )
      end
    end)
  end

  defp coordinate_cluster_owner(module, global_name, cluster_members, key, config, consumers) do
    case :global.whereis_name(global_name) do
      :undefined ->
        start_and_claim_global(module, global_name, key, config, consumers)

      pid when is_pid(pid) ->
        if owned_by_self?(module, key, pid) do
          start_and_claim_global(module, global_name, key, config, consumers)
        else
          reconcile_via_peer(
            module,
            global_name,
            cluster_members,
            pid,
            key,
            config,
            consumers
          )
        end
    end
  end

  defp reconcile_via_peer(module, global_name, cluster_members, pid, key, config, consumers) do
    case call_peer_reconcile(node(pid), cluster_members, pid, key, config, consumers) do
      {:ok, peer_pid} ->
        terminate_local_duplicate(module, key)
        remember_connection_spec(module, key, {config, consumers})
        {:ok, peer_pid, :peer}

      peer_gone when peer_gone in [:peer_unavailable, :peer_draining] ->
        start_and_claim_global(module, global_name, key, config, consumers)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_and_claim_global(module, global_name, key, config, consumers) do
    case ensure_local_owner_started(module, key, config, consumers) do
      {:ok, pid} ->
        :yes = :global.re_register_name(global_name, pid, &__MODULE__.resolve_global_conflict/3)
        remember_connection_spec(module, key, {config, consumers})
        {:ok, pid, :local}

      {:error, _reason} = error ->
        error
    end
  end

  defp call_peer_reconcile(peer_node, cluster_members, expected_pid, key, config, consumers) do
    :erpc.call(
      peer_node,
      __MODULE__,
      :reconcile_peer_owner,
      [cluster_members, expected_pid, key, config, consumers],
      @call_timeout
    )
  catch
    _, _ -> :peer_unavailable
  end

  @doc false
  def reconcile_peer_owner(cluster_members, expected_pid, key, config, consumers)
      when is_list(cluster_members) and is_pid(expected_pid) do
    case find_local_owner_module(cluster_members, expected_pid, key) do
      nil ->
        :peer_unavailable

      owner_module ->
        %{cluster_scope: cluster_scope, drain_state_key: drain_state_key} =
          owner_module.__connection_lifecycle__()

        global_name = global_owner_name(cluster_scope, key)

        if AnkoleWeb.EndpointDrain.draining?(drain_state_key) do
          terminate_local_duplicate(owner_module, key)
          :global.unregister_name(global_name)
          :peer_draining
        else
          case start_and_claim_global(owner_module, global_name, key, config, consumers) do
            {:ok, pid, :local} -> {:ok, pid}
            {:error, _reason} = error -> error
          end
        end
    end
  end

  defp find_local_owner_module(cluster_members, expected_pid, key) do
    if Process.alive?(expected_pid) do
      Enum.find(cluster_members, fn candidate ->
        owned_by_self?(candidate, key, expected_pid)
      end)
    else
      nil
    end
  end

  defp active_peer_owner(cluster_scope, cluster_members, key) do
    case :global.whereis_name(global_owner_name(cluster_scope, key)) do
      pid when is_pid(pid) ->
        peer_owner_info_remote(node(pid), cluster_members, pid, key)

      :undefined ->
        :none
    end
  end

  defp peer_owner_info_remote(peer_node, cluster_members, pid, key) do
    :erpc.call(
      peer_node,
      __MODULE__,
      :peer_owner_info,
      [cluster_members, pid, key],
      @peer_probe_timeout
    )
  catch
    _, _ -> :none
  end

  @doc false
  def peer_owner_info(cluster_members, pid, key)
      when is_list(cluster_members) and is_pid(pid) do
    case find_local_owner_module(cluster_members, pid, key) do
      nil ->
        :none

      owner_module ->
        if AnkoleWeb.EndpointDrain.draining?(
             owner_module.__connection_lifecycle__().drain_state_key
           ) do
          :none
        else
          {:ok, pid, Map.get(connection_specs(owner_module), key)}
        end
    end
  end

  defp peer_still_managing?(_module, _peer_node, :noconnection), do: false

  defp peer_still_managing?(module, peer_node, _reason) do
    %{cluster_members: cluster_members} = module.__connection_lifecycle__()
    excluded = if peer_node == node(), do: [module], else: []

    :erpc.call(
      peer_node,
      __MODULE__,
      :any_reconciler_active?,
      [cluster_members -- excluded],
      @peer_probe_timeout
    ) == true
  catch
    _, _ -> false
  end

  @doc false
  def any_reconciler_active?(modules) when is_list(modules) do
    Enum.any?(modules, fn candidate ->
      %{registry: registry, drain_state_key: drain_state_key} =
        candidate.__connection_lifecycle__()

      not AnkoleWeb.EndpointDrain.draining?(drain_state_key) and
        case Registry.meta(registry, @reconciler_pid_key) do
          {:ok, pid} when is_pid(pid) -> Process.alive?(pid)
          _ -> false
        end
    end)
  end

  @doc false
  def resolve_global_conflict({__MODULE__, :owner, scope, _key}, pid1, pid2) do
    Task.start(fn ->
      try do
        :erpc.cast(node(pid2), __MODULE__, :terminate_conflict_loser, [scope, pid2])
      catch
        _, _ -> :ok
      end
    end)

    pid1
  end

  @doc false
  def terminate_conflict_loser(scope, pid) when is_pid(pid) do
    members =
      if is_atom(scope) and function_exported?(scope, :__connection_lifecycle__, 0) do
        scope.__connection_lifecycle__().cluster_members
      else
        []
      end

    terminated? =
      Enum.any?(members, fn module ->
        %{supervisor: supervisor} = module.__connection_lifecycle__()
        DynamicSupervisor.terminate_child(supervisor, pid) == :ok
      end)

    if not terminated? do
      terminate_by_ancestor_supervisor(pid)
    end

    :ok
  end

  defp terminate_by_ancestor_supervisor(pid) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         [supervisor | _] <- Keyword.get(dict, :"$ancestors"),
         true <- is_atom(supervisor) or is_pid(supervisor) do
      _ = DynamicSupervisor.terminate_child(supervisor, pid)
    else
      _ -> Process.exit(pid, :shutdown)
    end
  end

  defp stop_on_peer(peer_node, cluster_members, key) do
    :erpc.call(peer_node, __MODULE__, :stop_peer_owner, [cluster_members, key], @call_timeout)
  catch
    _, _ -> :ok
  end

  @doc false
  def stop_peer_owner(cluster_members, key) when is_list(cluster_members) do
    Enum.each(cluster_members, &stop_local(&1, key))
    :ok
  end

  @doc false
  def forget_peer_connection_spec(cluster_members, key) when is_list(cluster_members) do
    Enum.each(cluster_members, &forget_connection_spec(&1, key))
    :ok
  end

  defp stop_local(module, key) do
    %{registry: registry, supervisor: supervisor} = module.__connection_lifecycle__()

    if Process.whereis(registry) do
      Registry.lock(registry, {__MODULE__, key}, fn ->
        forget_connection_spec(module, key)

        case Registry.lookup(registry, key) do
          [{pid, _value}] -> DynamicSupervisor.terminate_child(supervisor, pid)
          [] -> :ok
        end
      end)
    else
      :ok
    end
  end

  defp terminate_local_duplicate(module, key) do
    %{registry: registry, supervisor: supervisor} = module.__connection_lifecycle__()

    Registry.lock(registry, {__MODULE__, key}, fn ->
      case Registry.lookup(registry, key) do
        [{pid, _value}] -> _ = DynamicSupervisor.terminate_child(supervisor, pid)
        [] -> :ok
      end
    end)
  end

  defp ensure_local_owner_started(module, key, config, consumers) do
    %{registry: registry} = module.__connection_lifecycle__()

    Registry.lock(registry, {__MODULE__, key}, fn ->
      ensure_owner_started_unlocked(module, key, config, consumers)
    end)
  end

  defp ensure_owner_started_unlocked(module, key, config, consumers) do
    %{registry: registry} = module.__connection_lifecycle__()
    {tenant_id, _fingerprint} = value = registry_value(config, consumers)

    case Registry.lookup(registry, key) do
      [{pid, ^value}] -> {:ok, pid}
      [{pid, {^tenant_id, _other}}] -> restart_owner(module, pid, key, config, consumers)
      [{_pid, _other_tenant}] -> {:error, :connection_tenant_mismatch}
      [] -> start_local_owner(module, key, config, consumers)
    end
  end

  # `{:error, :not_found}` means the owner already exited on its own; its
  # replacement starts either way.
  defp restart_owner(module, pid, key, config, consumers) do
    %{supervisor: supervisor} = module.__connection_lifecycle__()
    forget_connection_spec(module, key)
    _result = DynamicSupervisor.terminate_child(supervisor, pid)
    start_local_owner(module, key, config, consumers)
  end

  defp start_local_owner(module, key, config, consumers) do
    %{supervisor: supervisor} = module.__connection_lifecycle__()

    case DynamicSupervisor.start_child(
           supervisor,
           module.owner_child_spec(key, config, consumers)
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        ensure_owner_started_unlocked(module, key, config, consumers)

      {:error, _reason} = error ->
        error
    end
  end

  defp owned_by_self?(module, key, pid) when is_pid(pid) do
    if node(pid) == node() do
      %{registry: registry} = module.__connection_lifecycle__()

      case Registry.lookup(registry, key) do
        [{^pid, _value}] -> Process.alive?(pid)
        _ -> false
      end
    else
      false
    end
  end

  defp global_lock_id(cluster_scope, key), do: {__MODULE__, :lock, cluster_scope, key}
  defp global_owner_name(cluster_scope, key), do: {__MODULE__, :owner, cluster_scope, key}

  defp global_keys(cluster_scope) do
    for {__MODULE__, :owner, ^cluster_scope, key} <- :global.registered_names(), do: key
  end

  defp await_cluster_sync do
    if pid = Process.whereis(DNSCluster) do
      try do
        _ = :sys.get_state(pid, @peer_probe_timeout)
      catch
        :exit, _ -> :ok
      end
    end

    if Node.list() != [] do
      _ = :global.sync()
    end

    :ok
  end

  defp connection_specs(module) do
    %{registry: registry} = module.__connection_lifecycle__()

    if Process.whereis(registry) do
      case Registry.meta(registry, @connection_specs_key) do
        {:ok, specs} -> specs
        :error -> %{}
      end
    else
      %{}
    end
  end

  defp remember_connection_spec(module, key, spec) do
    %{registry: registry} = module.__connection_lifecycle__()

    Registry.lock(registry, @connection_specs_key, fn ->
      Registry.put_meta(
        registry,
        @connection_specs_key,
        Map.put(connection_specs(module), key, spec)
      )
    end)
  end

  defp forget_connection_spec(module, key) do
    %{registry: registry} = module.__connection_lifecycle__()

    if Process.whereis(registry) do
      Registry.lock(registry, @connection_specs_key, fn ->
        Registry.put_meta(
          registry,
          @connection_specs_key,
          Map.delete(connection_specs(module), key)
        )
      end)
    else
      :ok
    end
  end
end
