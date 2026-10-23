defmodule Ankole.AgentWorkers.WorkerAdmission do
  @moduledoc """
  Connection facts of each Agent's Worker.

  `AgentWorkers` decides which Worker an Agent should have; this module records
  what its connection does, on the Agent's `agent_workers` row:

    * A Channel join is the only way into `ready` (`admit_join/2`). The socket
      already proved that the connection holds the credential of the current
      generation. Under the row lock, the join checks that this generation
      is still current, that the row may accept a process (`starting`,
      `stale`, or `ready`), and that its protocol version is this node's.
      Then one conditional update writes the route and incarnation. It
      changes no row while another incarnation has a fresh heartbeat.
    * Heartbeat messages only renew a row that is
      ready or draining on the same route and incarnation. A ready row whose
      capacity changes broadcast to the Agent's drivers.
    * A row whose connection breaks or goes silent becomes `stale`; the control
      plane closes the old connection, and a live process must connect again.

  Each change is a generic action of `AgentWorker`, which owns its
  transaction. Connection changes wake the Agent's drivers after the commit.
  A reconnect does not end a Codex attempt or consume input; the driver
  probes its existing operation. Times are database time.
  """

  require Ash.Query

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.Errors
  alias Ankole.Repo
  alias Ankole.RuntimeFabric
  alias Ankole.RuntimeFabric.V1, as: FabricProto

  @join_states [:starting, :stale, :ready]
  @connected_states [:ready, :draining]

  @type auth :: %{
          required(:transport_route) => String.t(),
          required(:worker_id) => String.t(),
          optional(:generation) => String.t()
        }

  @doc """
  Admits the process behind a Channel join.

  The join payload names the process incarnation and its capacity. The same
  incarnation on a new connection only moves the route. When the row enters `ready`
  from `starting` or `stale`, or a new incarnation replaces the old one,
  the change is broadcast to this Agent's drivers.
  """
  @spec admit_join(map(), auth()) ::
          {:ok, AgentWorker.t()} | {:error, term()}
  def admit_join(ready, auth) do
    with {:ok, %{route: route, agent_uid: agent_uid}} <- authenticated(auth),
         generation when is_binary(generation) and generation != "" <-
           Map.get(auth, :generation) || {:error, :stale_worker_generation},
         {:ok, attrs} <- ready_attrs(ready),
         {:ok, %{worker: worker}} <-
           Errors.reason(
             AgentWorkers.admit_worker(
               agent_uid,
               generation,
               route,
               attrs.incarnation_id,
               attrs.capacity
             )
           ),
         do: {:ok, worker}
  end

  @doc "Renews the row from a heartbeat on the admitted connection."
  @spec handle_worker_heartbeat(FabricProto.WorkerHeartbeat.t(), auth()) ::
          {:ok, AgentWorker.t()} | {:error, term()}
  def handle_worker_heartbeat(%FabricProto.WorkerHeartbeat{} = heartbeat, auth) do
    with {:ok, %{route: route, agent_uid: agent_uid}} <- authenticated(auth),
         {:ok, incarnation_id} <- required_text(heartbeat.incarnation_id, "incarnation_id"),
         {:ok, %{worker: worker}} <-
           Errors.reason(
             AgentWorkers.renew_worker_connection(
               agent_uid,
               route,
               incarnation_id,
               capacity(heartbeat.max_slots, heartbeat.available_slots),
               load(heartbeat.active_slots, heartbeat.active_tasks, heartbeat.idle_for_ms)
             )
           ),
         do: {:ok, worker}
  end

  @doc """
  Takes a draining Worker out of placement while its accepted Turns finish.

  The Worker reports it when it starts to drain, for example on SIGTERM. Its
  connection stays valid until the process exits.
  """
  @spec handle_control_shutdown(FabricProto.ControlShutdown.t(), auth()) ::
          {:ok, AgentWorker.t()} | {:error, term()}
  def handle_control_shutdown(%FabricProto.ControlShutdown{} = control_shutdown, auth) do
    with {:ok, %{route: route, agent_uid: agent_uid}} <- authenticated(auth),
         {:ok, reason} <- required_text(control_shutdown.reason, "reason"),
         do: Errors.reason(AgentWorkers.drain_worker_connection(agent_uid, route, reason))
  end

  @doc """
  Marks the Worker behind a broken route stale and releases its in-flight work.

  Only `:unknown_route` and `:socket_closed` mean that the connection is gone.
  Every other send failure leaves the Worker as it is: a `:stale_route` names
  a former connection of a Worker that is connected again, and a Worker that
  times out or applies backpressure is still connected; its heartbeat decides
  whether it is gone. A draining Worker keeps its state and loses only the
  connection.
  """
  @spec mark_route_unusable(String.t() | nil, term()) :: :ok | {:ok, term()} | {:error, term()}
  def mark_route_unusable(route, reason)
      when is_binary(route) and reason in [:unknown_route, :socket_closed] do
    case Errors.reason(AgentWorkers.release_worker_route(route)) do
      {:ok, %AgentWorker{}} -> {:ok, :marked_stale}
      {:ok, nil} -> {:ok, :route_not_registered}
      {:error, _reason} = error -> error
    end
  end

  def mark_route_unusable(_route, _reason), do: :ok

  @doc "Expires a connection after 60 seconds without a heartbeat, on any control-plane node."
  @spec expire_connection(String.t()) :: :ok | {:error, term()}
  def expire_connection(agent_uid) do
    with {:ok, _expired} <- Errors.reason(AgentWorkers.expire_worker_connection(agent_uid)),
         do: :ok
  end

  @doc false
  def admit_in_tx(%{agent_uid: agent_uid, generation: generation} = input) do
    case AgentWorkers.lock_in_tx(Repo, agent_uid) do
      %AgentWorker{state: state, generation: ^generation} = worker when state in @join_states ->
        if worker.protocol_version == RuntimeFabric.protocol_version(),
          do: admit_locked(worker, input),
          else: {:error, :protocol_mismatch}

      %AgentWorker{} ->
        {:error, :stale_worker_generation}

      nil ->
        {:error, :unknown_worker}
    end
  end

  # The locked row is current. A zero-row update means that another
  # incarnation still has a fresh heartbeat.
  defp admit_locked(worker, %{route: route} = input) do
    replaced_route = if worker.transport_route not in [nil, route], do: worker.transport_route

    attrs = %{
      transport_route: route,
      incarnation: input.incarnation,
      capacity: input.capacity
    }

    case Errors.reason(Ankole.Ash.update_atomic(worker, :admit, attrs)) do
      {:ok, worker} -> {:ok, %{worker: worker, replaced_route: replaced_route}}
      {:error, :stale} -> {:error, :worker_incarnation_active}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def publish_admission(%{worker: worker, replaced_route: replaced_route}) do
    AgentWorkers.notify_changed(worker.agent_uid)

    if replaced_route,
      do: WorkerRoute.close_connection(worker.agent_uid, replaced_route, :worker_route_replaced)
  end

  # One conditional UPDATE: the row must still be connected on this route
  # with this incarnation, so a message from an old connection or process
  # changes nothing. The row lock gives the previous capacity; a capacity
  # change wakes drivers that are waiting for a slot.
  @doc false
  def renew_in_tx(%{agent_uid: agent_uid} = input) do
    previous = AgentWorkers.lock_in_tx(Repo, agent_uid)
    attrs = Map.take(input, [:route, :incarnation, :capacity, :load])
    query = Ash.Query.filter(AgentWorker, agent_uid == ^agent_uid)

    case Errors.reason(Ankole.Ash.update_atomic(query, :heartbeat, attrs)) do
      {:ok, worker} -> {:ok, %{worker: worker, changed?: previous.capacity != worker.capacity}}
      {:error, :stale} -> {:error, :stale_transport_route}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def publish_renewal(%{worker: worker, changed?: changed?}),
    do: if(changed?, do: AgentWorkers.notify_changed(worker.agent_uid))

  @doc false
  def drain_in_tx(%{agent_uid: agent_uid, route: route, reason: reason}) do
    case AgentWorkers.lock_in_tx(Repo, agent_uid) do
      %AgentWorker{state: state, transport_route: ^route} = worker
      when state in @connected_states ->
        Ankole.Ash.update(worker, :drain, %{drain_reason: worker.drain_reason || reason})

      _worker ->
        {:error, :worker_not_ready}
    end
  end

  @doc false
  def release_route_in_tx(%{route: route}) do
    AgentWorker
    |> Ash.Query.filter(transport_route == ^route)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "agent_workers", :agent_uid})
    |> case do
      [worker] -> with {:ok, {worker, _route}} <- disconnect(worker), do: {:ok, worker}
      [] -> {:ok, nil}
    end
  end

  @doc false
  def publish_worker(nil), do: :ok

  def publish_worker(%AgentWorker{agent_uid: agent_uid}),
    do: AgentWorkers.notify_changed(agent_uid)

  @doc false
  def expire_in_tx(%{agent_uid: agent_uid}) do
    AgentWorker
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and state in ^@connected_states and not is_nil(transport_route) and
        (is_nil(last_worker_heartbeat_at) or
           last_worker_heartbeat_at <= fragment("clock_timestamp() - interval '60 seconds'"))
    )
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {"agent_workers", agent_uid})
    |> case do
      %AgentWorker{} = worker -> disconnect(worker)
      nil -> {:ok, nil}
    end
  end

  @doc false
  def publish_expiry(nil), do: :ok

  def publish_expiry({worker, route}) do
    AgentWorkers.notify_changed(worker.agent_uid)
    WorkerRoute.close_connection(worker.agent_uid, route, :worker_heartbeat_timeout)
  end

  # A draining connection loses its route without reopening placement.
  defp disconnect(%AgentWorker{} = worker) do
    route = worker.transport_route

    with {:ok, updated} <- Ankole.Ash.update(worker, :disconnect, %{}),
         do: {:ok, {updated, route}}
  end

  defp authenticated(%{transport_route: route, worker_id: agent_uid})
       when is_binary(route) and route != "" and is_binary(agent_uid) and agent_uid != "",
       do: {:ok, %{route: route, agent_uid: agent_uid}}

  defp authenticated(_auth), do: {:error, :unauthenticated_worker_route}

  defp ready_attrs(ready) do
    with {:ok, incarnation_id} <- required_text(ready.incarnation_id, "incarnation_id") do
      {:ok,
       %{
         incarnation_id: incarnation_id,
         capacity: capacity(ready.max_slots, ready.available_slots)
       }}
    end
  end

  defp capacity(max_slots, available_slots),
    do: %{"max_slots" => max_slots, "available_slots" => available_slots}

  defp load(active_slots, active_tasks, idle_for_ms) do
    %{
      "active_slots" => active_slots,
      "active_tasks" => active_tasks,
      "idle_for_ms" => idle_for_ms
    }
  end

  defp required_text(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_text(_value, key), do: {:error, {:missing, key}}
end
