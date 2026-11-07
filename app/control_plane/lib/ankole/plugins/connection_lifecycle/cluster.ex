defmodule Ankole.Plugins.ConnectionLifecycle.Cluster do
  @moduledoc """
  Coordinates single-owner connection processes and handover across connected BEAM nodes.

  Each plugin reconciler module acts as its own cluster scope: at most one replica
  holds `{Ankole.Plugins.ConnectionLifecycle.Cluster, :owner, module, key}` in
  `:global` at any moment. Reconcilers serialize transitions per `(module, key)`
  under `:global.trans/2`, update or stop remote owners via `:erpc`, and treat
  ambiguous remote RPC failures (such as `:timeout` on a still-connected peer) as
  in-flight errors rather than preemption authority so a slow peer never triggers
  dual-active external connections.
  """

  @connection_specs_key {__MODULE__, :connection_specs}
  @reconciler_pid_key {__MODULE__, :reconciler_pid}
  @default_peer_rpc_timeout_ms 15_000
  @default_peer_probe_timeout_ms 5_000
  @default_stop_timeout_ms 30_000

  @doc "Records the local reconciler PID in the plugin registry metadata."
  @spec register_reconciler(module(), pid()) :: :ok
  def register_reconciler(module, pid \\ self()) when is_atom(module) and is_pid(pid) do
    %{registry: registry} = module.__connection_lifecycle__()

    if Process.whereis(registry) do
      Registry.put_meta(registry, @reconciler_pid_key, pid)
    end

    :ok
  end

  @doc "Waits for initial cluster membership and `:global` synchronization."
  @spec await_sync() :: :ok
  def await_sync do
    if pid = Process.whereis(DNSCluster) do
      try do
        _ = :sys.get_state(pid, @default_peer_probe_timeout_ms)
      catch
        :exit, _ -> :ok
      end
    end

    if Node.list() != [] do
      _ = :global.sync()
    end

    :ok
  end

  @doc "Whether this node has entered graceful HTTP drain."
  @spec draining?() :: boolean()
  def draining?, do: AnkoleWeb.EndpointDrain.draining?()

  @doc "Whether a PubSub drain broadcast came from a peer node."
  @spec peer_drain_event?(term(), node()) :: boolean()
  def peer_drain_event?(drained_state_key, drained_node) do
    drained_state_key == AnkoleWeb.EndpointDrain.default_state_key() and drained_node != node()
  end

  @doc "Returns the registry value `{tenant_id, sha256_fingerprint}` for an owner."
  @spec registry_value(map(), [map()]) :: {String.t(), binary()}
  def registry_value(config, consumers) do
    {tenant_id!(consumers), :crypto.hash(:sha256, :erlang.term_to_binary({config, consumers}))}
  end

  @doc "Extracts the single tenant ID shared by all consumers of a connection."
  @spec tenant_id!([map()]) :: String.t()
  def tenant_id!(consumers) do
    case consumers |> Enum.map(&Map.fetch!(&1, :tenant_id)) |> Enum.uniq() do
      [tenant_id] -> tenant_id
      _ -> raise ArgumentError, "A platform connection must belong to exactly one tenant"
    end
  end

  @doc "Lists the connection keys of owners supervised on this node."
  @spec registered_keys(module()) :: [term()]
  def registered_keys(module) do
    module |> local_owners() |> Map.keys() |> Enum.sort()
  end

  @doc "Returns `%{key => {pid, :local}}` for all live owners under `module`'s supervisor."
  @spec local_owners(module()) :: %{optional(term()) => {pid(), :local}}
  def local_owners(module) do
    %{registry: registry, supervisor: supervisor} = module.__connection_lifecycle__()

    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        Enum.map(Registry.keys(registry, pid), &{&1, {pid, :local}})

      _restarting ->
        []
    end)
    |> Map.new()
  end

  @doc "Lists connection keys currently registered in `:global` for `module`."
  @spec global_keys(module()) :: [term()]
  def global_keys(module) do
    for {__MODULE__, :owner, ^module, key} <- :global.registered_names(), do: key
  end

  @doc "Ensures at most one owner serves `(module, key)` with `{config, consumers}` across the cluster."
  @spec ensure_owner(module(), term(), map(), [map()], keyword()) ::
          {:ok, pid(), :local | :peer} | {:draining, term()} | {:error, term()}
  def ensure_owner(module, key, config, consumers, opts \\ []) do
    global_name = global_owner_name(module, key)
    rpc_timeout = Keyword.get(opts, :peer_rpc_timeout_ms, @default_peer_rpc_timeout_ms)

    :global.trans({global_lock_id(module, key), self()}, fn ->
      if draining?() do
        release_local_on_drain(module, global_name, key)
        {:draining, key}
      else
        coordinate_owner(module, global_name, key, config, consumers, rpc_timeout)
      end
    end)
  end

  @doc "Stops the owner of `(module, key)` across the cluster and clears cached start specs."
  @spec stop(module(), term()) :: :ok | {:error, term()}
  def stop(module, key) do
    global_name = global_owner_name(module, key)

    :global.trans({global_lock_id(module, key), self()}, fn ->
      local_result = stop_local(module, key)
      peer_result = stop_global_holder(module, global_name, key)

      Enum.each(Node.list(), fn peer ->
        :erpc.cast(peer, __MODULE__, :forget_connection_spec, [module, key])
      end)

      if local_result == :ok, do: peer_result, else: local_result
    end)
  end

  @doc "Checks whether a connected peer node currently holds a live non-draining owner for `(module, key)`."
  @spec active_peer_owner(module(), term()) :: {:ok, pid(), nil | {map(), [map()]}} | :none
  def active_peer_owner(module, key) do
    case :global.whereis_name(global_owner_name(module, key)) do
      pid when is_pid(pid) and node(pid) != node() ->
        probe_peer_owner(node(pid), module, pid, key)

      _ ->
        :none
    end
  end

  @doc "Checks whether `peer_node` still runs an active, non-draining reconciler for `module`."
  @spec peer_still_managing?(module(), node(), term()) :: boolean()
  def peer_still_managing?(_module, _peer_node, :noconnection), do: false

  def peer_still_managing?(module, peer_node, _reason) do
    if peer_node == node() or peer_node not in Node.list() do
      false
    else
      try do
        :erpc.call(
          peer_node,
          __MODULE__,
          :reconciler_active?,
          [module],
          @default_peer_probe_timeout_ms
        ) == true
      catch
        _, _ -> false
      end
    end
  end

  @doc "Looks up the tenant ID of an existing or cached owner locally or on its owning peer."
  @spec owner_tenant_id(module(), term()) :: {:ok, String.t()} | :error
  def owner_tenant_id(module, key) do
    case lookup_local_tenant_id(module, key) do
      {:ok, _tenant_id} = ok ->
        ok

      :error ->
        case Map.fetch(connection_specs(module), key) do
          {:ok, {_config, consumers}} -> {:ok, tenant_id!(consumers)}
          :error -> lookup_peer_tenant_id(module, key)
        end
    end
  end

  @doc "Returns the cached `{config, consumers}` map stored in `module`'s registry metadata."
  @spec connection_specs(module()) :: map()
  def connection_specs(module) do
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

  @doc "Persists `{config, consumers}` in `module`'s registry metadata for standby/crash resume."
  @spec remember_connection_spec(module(), term(), {map(), [map()]}) :: :ok
  def remember_connection_spec(module, key, spec) do
    %{registry: registry} = module.__connection_lifecycle__()

    Registry.lock(registry, @connection_specs_key, fn ->
      Registry.put_meta(
        registry,
        @connection_specs_key,
        Map.put(connection_specs(module), key, spec)
      )
    end)
  end

  @doc "Deletes `key` from `module`'s cached connection specs."
  @spec forget_connection_spec(module(), term()) :: :ok
  def forget_connection_spec(module, key) do
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

  @doc false
  def lookup_local_tenant_id(module, key) when is_atom(module) do
    %{registry: registry} = module.__connection_lifecycle__()

    case Registry.lookup(registry, key) do
      [{_pid, {tenant_id, _fingerprint}}] -> {:ok, tenant_id}
      [] -> :error
    end
  end

  @doc false
  def reconciler_active?(module) when is_atom(module) do
    %{registry: registry} = module.__connection_lifecycle__()

    not draining?() and
      case Registry.meta(registry, @reconciler_pid_key) do
        {:ok, pid} when is_pid(pid) -> Process.alive?(pid)
        _ -> false
      end
  end

  @doc false
  def peer_owner_info(module, pid, key) when is_atom(module) and is_pid(pid) do
    if not draining?() and owned_by_local?(module, key, pid) do
      {:ok, pid, Map.get(connection_specs(module), key)}
    else
      :none
    end
  end

  @doc false
  def reconcile_peer_owner(module, expected_pid, key, config, consumers)
      when is_atom(module) and is_pid(expected_pid) do
    global_name = global_owner_name(module, key)

    cond do
      draining?() ->
        release_local_on_drain(module, global_name, key)
        :peer_draining

      owned_by_local?(module, key, expected_pid) ->
        case claim_local_owner(module, global_name, key, config, consumers) do
          {:ok, pid, :local} -> {:ok, pid}
          {:error, _reason} = error -> error
        end

      true ->
        evict_stale_local_pid(module, global_name, expected_pid)
    end
  end

  @doc false
  def stop_peer_owner(module, key) when is_atom(module) do
    global_name = global_owner_name(module, key)
    result = stop_local(module, key)
    unregister_dead_local_global(global_name)
    result
  end

  @doc false
  def resolve_global_conflict({__MODULE__, :owner, module, _key}, pid1, pid2) do
    Task.start(fn ->
      try do
        :erpc.cast(node(pid2), __MODULE__, :terminate_conflict_loser, [module, pid2])
      catch
        _, _ -> :ok
      end
    end)

    pid1
  end

  @doc false
  def terminate_conflict_loser(module, pid) when is_atom(module) and is_pid(pid) do
    terminated? =
      if function_exported?(module, :__connection_lifecycle__, 0) do
        %{supervisor: supervisor} = module.__connection_lifecycle__()
        DynamicSupervisor.terminate_child(supervisor, pid) == :ok
      else
        false
      end

    if not terminated? do
      terminate_by_ancestor_supervisor(pid)
    end

    :ok
  end

  defp coordinate_owner(module, global_name, key, config, consumers, rpc_timeout) do
    case :global.whereis_name(global_name) do
      :undefined ->
        claim_local_owner(module, global_name, key, config, consumers)

      pid when is_pid(pid) and node(pid) == node() ->
        coordinate_same_node_owner(module, global_name, pid, key, config, consumers)

      pid when is_pid(pid) ->
        reconcile_via_peer(module, global_name, pid, key, config, consumers, rpc_timeout)
    end
  end

  defp coordinate_same_node_owner(module, global_name, pid, key, config, consumers) do
    if owned_by_local?(module, key, pid) do
      claim_local_owner(module, global_name, key, config, consumers)
    else
      case evict_stale_local_pid(module, global_name, pid) do
        :peer_owner_absent -> claim_local_owner(module, global_name, key, config, consumers)
        {:error, _reason} = error -> error
      end
    end
  end

  defp evict_stale_local_pid(module, global_name, pid) do
    if Process.alive?(pid) do
      %{supervisor: supervisor} = module.__connection_lifecycle__()
      _ = DynamicSupervisor.terminate_child(supervisor, pid)
    end

    if Process.alive?(pid) do
      {:error, {:owner_busy, pid}}
    else
      if :global.whereis_name(global_name) == pid do
        :global.unregister_name(global_name)
      end

      :peer_owner_absent
    end
  end

  defp reconcile_via_peer(module, global_name, pid, key, config, consumers, rpc_timeout) do
    case call_peer_reconcile(node(pid), module, pid, key, config, consumers, rpc_timeout) do
      {:ok, peer_pid} ->
        terminate_local_duplicate(module, key)
        remember_connection_spec(module, key, {config, consumers})
        {:ok, peer_pid, :peer}

      handover when handover in [:peer_disconnected, :peer_owner_absent, :peer_draining] ->
        claim_local_owner(module, global_name, key, config, consumers)

      {:error, _reason} = error ->
        error
    end
  end

  defp call_peer_reconcile(peer_node, module, expected_pid, key, config, consumers, rpc_timeout) do
    if peer_node in Node.list() do
      try do
        :erpc.call(
          peer_node,
          __MODULE__,
          :reconcile_peer_owner,
          [module, expected_pid, key, config, consumers],
          rpc_timeout
        )
      catch
        :error, {:erpc, :noconnection} ->
          :peer_disconnected

        :error, {:erpc, erpc_reason} ->
          {:error, {:peer_reconcile_failed, erpc_reason}}

        kind, reason ->
          {:error, {:peer_reconcile_failed, {kind, reason}}}
      end
    else
      :peer_disconnected
    end
  end

  defp claim_local_owner(module, global_name, key, config, consumers) do
    case ensure_local_owner_started(module, global_name, key, config, consumers) do
      {:ok, pid} ->
        case register_global_owner(global_name, pid) do
          :ok ->
            remember_connection_spec(module, key, {config, consumers})
            {:ok, pid, :local}

          {:error, _reason} = error ->
            %{supervisor: supervisor} = module.__connection_lifecycle__()
            _ = DynamicSupervisor.terminate_child(supervisor, pid)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp register_global_owner(global_name, pid) do
    case :global.whereis_name(global_name) do
      ^pid ->
        :ok

      existing when is_pid(existing) and node(existing) == node() ->
        if Process.alive?(existing) do
          {:error, {:global_name_taken, existing}}
        else
          :global.unregister_name(global_name)
          do_register_global(global_name, pid)
        end

      existing when is_pid(existing) ->
        if node(existing) in Node.list() do
          {:error, {:global_name_taken, existing}}
        else
          :global.unregister_name(global_name)
          do_register_global(global_name, pid)
        end

      :undefined ->
        do_register_global(global_name, pid)
    end
  end

  defp do_register_global(global_name, pid) do
    case :global.register_name(global_name, pid, &__MODULE__.resolve_global_conflict/3) do
      :yes -> :ok
      :no -> {:error, {:global_name_taken, :global.whereis_name(global_name)}}
    end
  end

  defp ensure_local_owner_started(module, global_name, key, config, consumers) do
    %{registry: registry} = module.__connection_lifecycle__()

    Registry.lock(registry, {__MODULE__, key}, fn ->
      ensure_owner_started_unlocked(module, global_name, key, config, consumers)
    end)
  end

  defp ensure_owner_started_unlocked(module, global_name, key, config, consumers) do
    %{registry: registry} = module.__connection_lifecycle__()
    {tenant_id, _fingerprint} = value = registry_value(config, consumers)

    case Registry.lookup(registry, key) do
      [{pid, ^value}] ->
        {:ok, pid}

      [{pid, {^tenant_id, _other}}] ->
        restart_owner(module, global_name, pid, key, config, consumers)

      [{_pid, _other_tenant}] ->
        {:error, :connection_tenant_mismatch}

      [] ->
        start_local_owner(module, global_name, key, config, consumers)
    end
  end

  defp restart_owner(module, global_name, pid, key, config, consumers) do
    %{supervisor: supervisor} = module.__connection_lifecycle__()
    forget_connection_spec(module, key)
    _ = DynamicSupervisor.terminate_child(supervisor, pid)

    if not Process.alive?(pid) and :global.whereis_name(global_name) == pid do
      :global.unregister_name(global_name)
    end

    start_local_owner(module, global_name, key, config, consumers)
  end

  defp start_local_owner(module, global_name, key, config, consumers) do
    %{supervisor: supervisor} = module.__connection_lifecycle__()

    case DynamicSupervisor.start_child(
           supervisor,
           module.owner_child_spec(key, config, consumers)
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        ensure_owner_started_unlocked(module, global_name, key, config, consumers)

      {:error, _reason} = error ->
        error
    end
  end

  defp release_local_on_drain(module, global_name, key) do
    terminate_local_duplicate(module, key)
    unregister_dead_local_global(global_name)
  end

  defp unregister_dead_local_global(global_name) do
    case :global.whereis_name(global_name) do
      pid when is_pid(pid) and node(pid) == node() ->
        if not Process.alive?(pid), do: :global.unregister_name(global_name)
        :ok

      _ ->
        :ok
    end
  end

  defp stop_global_holder(module, global_name, key) do
    case :global.whereis_name(global_name) do
      :undefined ->
        :ok

      pid when is_pid(pid) and node(pid) == node() ->
        unregister_dead_local_global(global_name)

      pid when is_pid(pid) ->
        stop_on_peer(node(pid), module, global_name, key)
    end
  end

  defp stop_on_peer(peer_node, module, global_name, key) do
    if peer_node in Node.list() do
      try do
        :erpc.call(
          peer_node,
          __MODULE__,
          :stop_peer_owner,
          [module, key],
          @default_stop_timeout_ms
        )
      catch
        :error, {:erpc, :noconnection} ->
          :global.unregister_name(global_name)
          :ok

        :error, {:erpc, reason} ->
          {:error, {:peer_stop_failed, reason}}

        kind, reason ->
          {:error, {:peer_stop_failed, {kind, reason}}}
      end
    else
      :global.unregister_name(global_name)
      :ok
    end
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

    if Process.whereis(registry) do
      Registry.lock(registry, {__MODULE__, key}, fn ->
        case Registry.lookup(registry, key) do
          [{pid, _value}] -> _ = DynamicSupervisor.terminate_child(supervisor, pid)
          [] -> :ok
        end
      end)
    end

    :ok
  end

  defp probe_peer_owner(peer_node, module, pid, key) do
    if peer_node in Node.list() do
      try do
        :erpc.call(
          peer_node,
          __MODULE__,
          :peer_owner_info,
          [module, pid, key],
          @default_peer_probe_timeout_ms
        )
      catch
        :error, {:erpc, :noconnection} ->
          :none

        _, _ ->
          {:ok, pid, nil}
      end
    else
      :none
    end
  end

  defp lookup_peer_tenant_id(module, key) do
    case :global.whereis_name(global_owner_name(module, key)) do
      pid when is_pid(pid) and node(pid) != node() ->
        try do
          :erpc.call(
            node(pid),
            __MODULE__,
            :lookup_local_tenant_id,
            [module, key],
            @default_peer_probe_timeout_ms
          )
        catch
          _, _ -> :error
        end

      _ ->
        :error
    end
  end

  defp owned_by_local?(module, key, pid) when is_pid(pid) do
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

  defp terminate_by_ancestor_supervisor(pid) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         [supervisor | _] <- Keyword.get(dict, :"$ancestors"),
         true <- is_atom(supervisor) or is_pid(supervisor) do
      _ = DynamicSupervisor.terminate_child(supervisor, pid)
    else
      _ -> Process.exit(pid, :shutdown)
    end
  end

  defp global_lock_id(module, key), do: {__MODULE__, :lock, module, key}
  defp global_owner_name(module, key), do: {__MODULE__, :owner, module, key}
end
