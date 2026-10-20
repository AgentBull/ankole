defmodule Ankole.Plugins.ConnectionLifecycle do
  @moduledoc """
  Keeps one plugin's long connections equal to its enabled bindings.

  A plugin declares its connection set with
  `use Ankole.Plugins.ConnectionLifecycle` and implements the callbacks of this
  module. This module owns the periodic reconcile process, the merge of binding
  and identity-provider specs by connection key, and restart attempts for each
  supervised connection process. The plugin owns its config, its consumers, and
  its client protocol. The connection Registry retains the last successful
  start arguments. The reconciler can resume that connection after it restarts,
  even when the current binding snapshot is blocked.

  Each owner registers under its connection key with `registry_value/2` of the
  config and consumers it serves. When the desired value differs, for example
  after a rotated secret or a changed consumer set, the owner is replaced.

  The `use` options are `:adapter` (the binding adapter id), `:registry` and
  `:supervisor` (the plugin's owner Registry and DynamicSupervisor), and the
  optional `:interval_ms` (default 60 seconds) and `:conflict_reason` (default
  `:conflicting_app_secret`), and `:restart_backoff_ms` (default 0, 5 seconds,
  then 30 seconds).
  """

  use GenServer

  alias Ankole.Repo
  alias Ankole.IdentityProviders
  alias Ankole.Logging

  alias Ankole.Signals.Binding

  @call_timeout 30_000
  @connection_specs_key {__MODULE__, :connection_specs}

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

  @doc "Returns the registry key of the owner that serves this config and consumer list."
  @callback connection_key(config :: map(), consumers :: [map()]) :: term()

  @doc "Returns the child spec that starts the owner of one connection."
  @callback owner_child_spec(key :: term(), config :: map(), consumers :: [map()]) ::
              Supervisor.child_spec() | {module(), term()}

  @optional_callbacks identity_spec: 1

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Ankole.Plugins.ConnectionLifecycle

      @connection_lifecycle %{
        adapter: Keyword.fetch!(opts, :adapter),
        registry: Keyword.fetch!(opts, :registry),
        supervisor: Keyword.fetch!(opts, :supervisor),
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

      @doc "Stops the owner registered under a connection key, if any."
      @spec stop(term()) :: :ok | {:error, term()}
      def stop(key), do: Ankole.Plugins.ConnectionLifecycle.stop(__MODULE__, key)

      @doc "Lists the connection keys of the owners running in this node."
      @spec registered_keys() :: [term()]
      def registered_keys, do: Ankole.Plugins.ConnectionLifecycle.registered_keys(__MODULE__)
    end
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
      failures: %{}
    }

    GenServer.start_link(__MODULE__, state, name: Keyword.get(opts, :name, module))
  end

  @doc false
  @spec reconcile(GenServer.server()) :: map()
  def reconcile(server), do: GenServer.call(server, :reconcile, @call_timeout)

  @doc false
  @spec reconcile_async(GenServer.server()) :: :ok
  def reconcile_async(server), do: GenServer.cast(server, :reconcile)

  @doc false
  @spec reconcile_once(module(), keyword()) :: map()
  def reconcile_once(module, opts) when is_atom(module) and is_list(opts) do
    module |> reconcile_connections(opts) |> Map.delete(:connections)
  end

  defp reconcile_connections(module, opts) do
    config = module.__connection_lifecycle__()

    {specs, errors} =
      Ankole.Tenants.Tenant
      |> Repo.all()
      |> Enum.reduce({%{}, []}, fn tenant, acc ->
        Repo.with_tenant(tenant.id, fn ->
          try do
            config.adapter
            |> Ankole.Signals.Bindings.list_enabled_bindings(Keyword.take(opts, [:repo]))
            |> Enum.reduce(acc, &add_binding(module, config, &1, &2, opts))
            |> add_identity_providers(module, config)
          rescue
            error ->
              {specs, errors} = acc

              {specs,
               [
                 %{tenant_id: tenant.id, reason: {:snapshot_failed, Exception.message(error)}}
                 | errors
               ]}
          end
        end)
      end)

    stopped = stop_undesired(module, specs, errors)
    blocked_keys = MapSet.new(for %{blocked_connection_key: key} <- errors, do: key)

    {started, failed} =
      specs
      # A blocked binding can share its key with an identity provider. Starting
      # that partial spec would replace the live connection without the chat
      # consumer of the blocked binding.
      |> Enum.reject(fn {key, _spec} -> MapSet.member?(blocked_keys, key) end)
      |> Enum.map(fn {key, spec} ->
        {key, tenant_id!(spec.consumers),
         ensure_owner_started(module, key, spec.config, Enum.reverse(spec.consumers))}
      end)
      |> Enum.split_with(&match?({_key, _tenant_id, {:ok, _pid}}, &1))

    %{
      connections: Map.new(started, fn {key, _tenant_id, {:ok, pid}} -> {key, pid} end),
      started: length(started),
      stopped: stopped,
      errors:
        Enum.reverse(errors) ++
          Enum.map(failed, fn {_key, tenant_id, {:error, reason}} ->
            %{tenant_id: tenant_id, reason: reason}
          end)
    }
  end

  @doc false
  @spec stop(module(), term()) :: :ok | {:error, term()}
  def stop(module, key) do
    %{registry: registry, supervisor: supervisor} = module.__connection_lifecycle__()

    Registry.lock(registry, {__MODULE__, key}, fn ->
      forget_connection_spec(module, key)

      case Registry.lookup(registry, key) do
        [{pid, _value}] -> DynamicSupervisor.terminate_child(supervisor, pid)
        [] -> :ok
      end
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
    if handler = Application.get_env(:ankole, :connection_lifecycle_error_handler) do
      Process.flag(:error_handler, handler)
    end

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
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

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{key, _pid}, monitors} ->
        state = %{state | monitors: monitors}

        if reason == :shutdown do
          {:noreply, %{state | failures: Map.delete(state.failures, key)}}
        else
          {:noreply, retry_key(state, key, reason)}
        end
    end
  end

  def handle_info({:restart_key, key}, state) do
    %{registry: registry} = state.module.__connection_lifecycle__()

    case {Map.fetch(connection_specs(state.module), key), Registry.lookup(registry, key)} do
      {{:ok, {config, consumers}}, []} ->
        case ensure_owner_started(state.module, key, config, consumers) do
          {:ok, pid} -> {:noreply, monitor_key(state, key, pid)}
          {:error, reason} -> {:noreply, retry_key(state, key, reason)}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(%{state: state} = status) do
    %{
      status
      | state: Map.take(state, [:module, :interval_ms, :restart_backoff_ms, :monitors, :failures])
    }
  end

  defp run_reconcile(%{module: module, reconcile_opts: opts} = state) do
    result = reconcile_connections(module, opts)

    if result.errors != [] do
      adapter = module.__connection_lifecycle__().adapter

      Logging.warning(
        "#{adapter}_adapter.connection_reconciliation.completed_with_errors",
        "#{adapter} adapter connection reconciliation completed with errors",
        %{errors: result.errors}
      )
    end

    %{registry: registry, supervisor: supervisor} = module.__connection_lifecycle__()

    live =
      supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          Enum.map(Registry.keys(registry, pid), &{&1, pid})

        _restarting ->
          []
      end)
      |> Map.new()

    # The Registry keeps the successful start arguments after a client exits.
    # A new reconciler can thus resume a blocked connection even if its client
    # exited while the reconciler was restarting.
    {resumed, failed} =
      module
      |> connection_specs()
      |> Enum.reject(fn {key, _spec} ->
        Map.has_key?(live, key) or Map.has_key?(result.connections, key)
      end)
      |> Enum.map(fn {key, {config, consumers}} ->
        {key, tenant_id!(consumers), ensure_owner_started(module, key, config, consumers)}
      end)
      |> Enum.split_with(&match?({_key, _tenant_id, {:ok, _pid}}, &1))

    result = %{
      result
      | started: result.started + length(resumed),
        connections:
          Map.merge(
            result.connections,
            Map.new(resumed, fn {key, _tenant_id, {:ok, pid}} -> {key, pid} end)
          ),
        errors:
          result.errors ++
            Enum.map(failed, fn {_key, tenant_id, {:error, reason}} ->
              %{tenant_id: tenant_id, reason: reason}
            end)
    }

    {monitors, failures} =
      Enum.reduce(state.monitors, {%{}, state.failures}, fn {ref, {key, pid}},
                                                            {monitors, failures} ->
        if Map.get(live, key) == pid do
          {Map.put(monitors, ref, {key, pid}), Map.delete(failures, key)}
        else
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
      Enum.reduce(failed, state, fn {key, _tenant_id, {:error, reason}}, state ->
        retry_key(state, key, reason)
      end)

    # A client can exit before which_children/1 observes it. Monitor the
    # actual start result too, so its DOWN still reaches the restart owner.
    state =
      Enum.reduce(Map.merge(result.connections, live), state, fn {key, pid}, state ->
        monitor_key(state, key, pid)
      end)

    {Map.drop(result, [:desired, :connections]), state}
  end

  defp monitor_key(state, key, pid) do
    if Enum.any?(state.monitors, fn {_ref, {_key, monitored}} -> monitored == pid end) do
      state
    else
      %{state | monitors: Map.put(state.monitors, Process.monitor(pid), {key, pid})}
    end
  end

  defp retry_key(state, key, reason) do
    attempt = Map.get(state.failures, key, 0) + 1
    adapter = state.module.__connection_lifecycle__().adapter

    Logging.warning(
      "#{adapter}_adapter.connection.client_exited",
      "#{adapter} adapter connection client exited",
      %{connection_key: inspect(key), reason: inspect(reason), attempt: attempt}
    )

    delay = Enum.at(state.restart_backoff_ms, attempt - 1, List.last(state.restart_backoff_ms))
    Process.send_after(self(), {:restart_key, key}, delay)
    %{state | failures: Map.put(state.failures, key, attempt)}
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
        {specs, [Map.merge(error, %{reason: reason, blocked_connection_key: key}) | errors]}

      {:error, reason} ->
        {specs, [Map.put(error, :reason, reason) | errors]}
    end
  end

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
        {specs, [Map.put(error, :reason, reason) | errors]}
    end
  end

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
            error =
              Map.merge(conflict, %{
                reason: :connection_tenant_mismatch
              })

            %{registry: registry} = module.__connection_lifecycle__()

            keep =
              case Registry.lookup(registry, key) do
                [{_pid, {tenant_id, _fingerprint}}] ->
                  if tenant_id == tenant_id!(spec.consumers), do: spec, else: existing

                [] ->
                  existing
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
    %{registry: registry} = module.__connection_lifecycle__()

    (registered_keys(module) ++ Map.keys(connection_specs(module)))
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(specs, &1))
    |> Enum.reject(fn key ->
      case Registry.lookup(registry, key) do
        [{_pid, {tenant_id, _fingerprint}}] ->
          MapSet.member?(failed_tenants, tenant_id)

        [] ->
          case Map.fetch(connection_specs(module), key) do
            {:ok, {_config, consumers}} ->
              MapSet.member?(failed_tenants, tenant_id!(consumers))

            :error ->
              false
          end
      end
    end)
    |> Enum.count(&(stop(module, &1) == :ok))
  end

  defp ensure_owner_started(module, key, config, consumers) do
    %{registry: registry} = module.__connection_lifecycle__()

    Registry.lock(registry, {__MODULE__, key}, fn ->
      case ensure_owner_started_unlocked(module, key, config, consumers) do
        {:ok, _pid} = result ->
          remember_connection_spec(module, key, {config, consumers})
          result

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp ensure_owner_started_unlocked(module, key, config, consumers) do
    %{registry: registry} = module.__connection_lifecycle__()
    {tenant_id, _fingerprint} = value = registry_value(config, consumers)

    case Registry.lookup(registry, key) do
      [{pid, ^value}] -> {:ok, pid}
      [{pid, {^tenant_id, _other}}] -> restart_owner(module, pid, key, config, consumers)
      [{_pid, _other_tenant}] -> {:error, :connection_tenant_mismatch}
      [] -> start_owner(module, key, config, consumers)
    end
  end

  # `{:error, :not_found}` means the owner already exited on its own; its
  # replacement starts either way.
  defp restart_owner(module, pid, key, config, consumers) do
    %{supervisor: supervisor} = module.__connection_lifecycle__()
    forget_connection_spec(module, key)
    _result = DynamicSupervisor.terminate_child(supervisor, pid)
    start_owner(module, key, config, consumers)
  end

  defp start_owner(module, key, config, consumers) do
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

  defp connection_specs(module) do
    %{registry: registry} = module.__connection_lifecycle__()

    case Registry.meta(registry, @connection_specs_key) do
      {:ok, specs} -> specs
      :error -> %{}
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

    Registry.lock(registry, @connection_specs_key, fn ->
      Registry.put_meta(
        registry,
        @connection_specs_key,
        Map.delete(connection_specs(module), key)
      )
    end)
  end
end
