defmodule Ankole.SignalsGateway.ActorRuntime.WorkerAdmission do
  @moduledoc """
  Connection facts of each Agent's Worker.

  `AgentWorkers` decides which Worker an Agent should have; this module records
  what its connection does, on the Agent's `agent_workers` row:

    * A Channel join is the only way into `ready` (`admit_join/2`). The socket
      already proved that the connection holds the credential of the current
      generation. The join checks, under the row lock, that this generation
      is still current, that the row may accept a process (`starting`,
      `stale`, or `ready`), and that its protocol version is this node's,
      rejects a new incarnation while the current connection has a fresh
      heartbeat, then writes the route and incarnation.
    * Heartbeat messages only renew a row that is
      ready or draining on the same route and incarnation. A ready row whose
      capacity changes broadcast to the Agent's drivers.
    * A row whose connection breaks or goes silent becomes `stale`; the control
      plane closes the old connection, and a live process must connect again.

  Connection changes wake the Agent's drivers. A reconnect does not end a
  Codex attempt or consume input; the driver probes its existing operation.
  Times are database time.
  """

  import Ecto.Query, warn: false

  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute

  @join_states ~w(starting stale ready)
  @connected_states ~w(ready draining)

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
         {:ok, attrs} <- ready_attrs(ready) do
      result =
        Repo.transact(fn repo -> admit_in_tx(repo, agent_uid, generation, route, attrs) end)

      case result do
        {:ok, %{worker: worker, replaced_route: replaced_route}} ->
          AgentWorkers.notify_changed(agent_uid)
          close_replaced_route(agent_uid, replaced_route, :worker_route_replaced)
          {:ok, worker}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Renews the row from a heartbeat on the admitted connection."
  @spec handle_worker_heartbeat(FabricProto.AgentComputerWorkerHeartbeat.t(), auth()) ::
          {:ok, AgentWorker.t()} | {:error, term()}
  def handle_worker_heartbeat(%FabricProto.AgentComputerWorkerHeartbeat{} = heartbeat, auth) do
    with {:ok, %{route: route, agent_uid: agent_uid}} <- authenticated(auth),
         {:ok, incarnation_id} <- required_text(heartbeat.incarnation_id, "incarnation_id") do
      renew(agent_uid, incarnation_id, route, %{
        capacity: capacity(heartbeat.max_slots, heartbeat.available_slots),
        load: load(heartbeat.active_slots, heartbeat.active_tasks, heartbeat.idle_for_ms)
      })
    end
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
         {:ok, reason} <- required_text(control_shutdown.reason, "reason") do
      Repo.transact(fn repo ->
        case AgentWorkers.lock_in_tx(repo, agent_uid) do
          %AgentWorker{state: state, transport_route: ^route} = worker
          when state in @connected_states ->
            with {:ok, worker} <- mark_draining(repo, worker, reason) do
              {:ok, worker}
            end

          _worker ->
            {:error, :worker_not_ready}
        end
      end)
      |> tap(fn
        {:ok, _worker} -> AgentWorkers.notify_changed(agent_uid)
        _error -> :ok
      end)
    end
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
    Repo.transact(fn repo ->
      case lock_by_route(repo, route) do
        %AgentWorker{} = worker ->
          with {:ok, {worker, _route}} <- disconnect(repo, worker, Atom.to_string(reason)) do
            {:ok, worker}
          end

        nil ->
          {:ok, :route_not_registered}
      end
    end)
    |> case do
      {:ok, %AgentWorker{} = worker} ->
        AgentWorkers.notify_changed(worker.agent_uid)
        {:ok, :marked_stale}

      result ->
        result
    end
  end

  def mark_route_unusable(_route, _reason), do: :ok

  defp admit_in_tx(repo, agent_uid, generation, route, attrs) do
    case AgentWorkers.lock_in_tx(repo, agent_uid) do
      %AgentWorker{state: state, generation: ^generation} = worker when state in @join_states ->
        with :ok <- same_protocol(worker),
             :ok <- admit_incarnation(repo, worker, attrs.incarnation_id) do
          replaced_route =
            if worker.transport_route not in [nil, route], do: worker.transport_route

          {:ok, worker} =
            update_row(repo, agent_uid,
              state: "ready",
              incarnation_id: attrs.incarnation_id,
              transport_route: route,
              capacity: attrs.capacity,
              last_error: nil,
              last_error_kind: nil,
              state_changed?: worker.state != "ready"
            )

          {:ok, %{worker: worker, replaced_route: replaced_route}}
        end

      %AgentWorker{} ->
        {:error, :stale_worker_generation}

      nil ->
        {:error, :unknown_worker}
    end
  end

  defp admit_incarnation(repo, worker, incarnation_id) do
    competing? =
      worker.incarnation_id not in [nil, incarnation_id] and
        not is_nil(worker.transport_route)

    if competing? and
         repo.exists?(
           from w in AgentWorker,
             where: w.agent_uid == ^worker.agent_uid,
             where:
               w.last_worker_heartbeat_at > fragment("clock_timestamp() - interval '60 seconds'")
         ) do
      {:error, :worker_incarnation_active}
    else
      :ok
    end
  end

  defp same_protocol(%AgentWorker{protocol_version: version}) do
    if version == RuntimeFabric.protocol_version(), do: :ok, else: {:error, :protocol_mismatch}
  end

  # One conditional UPDATE: the row must still be connected on this route
  # with this incarnation, so a message from an old connection or process
  # changes nothing.
  #
  # A capacity change wakes drivers that are waiting for a slot.
  defp renew(agent_uid, incarnation_id, route, changes) do
    query =
      from worker in AgentWorker,
        where:
          worker.agent_uid == ^agent_uid and worker.state in ^@connected_states and
            worker.transport_route == ^route and worker.incarnation_id == ^incarnation_id,
        update: [set: [last_worker_heartbeat_at: fragment("now()")]],
        select: worker

    sets =
      Enum.reject(Map.take(changes, [:capacity, :load]), fn {_key, value} -> is_nil(value) end)

    query = if sets == [], do: query, else: update(query, set: ^sets)

    result =
      Repo.transact(fn repo ->
        previous = AgentWorkers.lock_in_tx(repo, agent_uid)

        case repo.update_all(query, []) do
          {1, [worker]} ->
            {:ok, {worker, previous.capacity != worker.capacity}}

          {0, []} ->
            {:error, :stale_transport_route}
        end
      end)

    case result do
      {:ok, {worker, changed?}} ->
        if changed?, do: AgentWorkers.notify_changed(agent_uid)
        {:ok, worker}

      {:error, _reason} = error ->
        error
    end
  end

  defp mark_draining(repo, %AgentWorker{} = worker, reason) do
    update_row(repo, worker.agent_uid,
      state: "draining",
      capacity: Map.put(worker.capacity, "available_slots", 0),
      drain_reason: worker.drain_reason || reason,
      state_changed?: worker.state != "draining"
    )
  end

  # The connection is gone: a ready row becomes stale, a draining row keeps
  # draining without a connection, and the Agent's in-flight work is released.
  defp disconnect(repo, %AgentWorker{} = worker, _reason) do
    route = worker.transport_route

    with {:ok, updated} <-
           update_row(repo, worker.agent_uid,
             state: if(worker.state == "ready", do: "stale", else: worker.state),
             transport_route: nil,
             state_changed?: worker.state == "ready"
           ) do
      {:ok, {updated, route}}
    end
  end

  # Writes the connection columns in database time. `state_changed?: true`
  # moves `state_changed_at` to now.
  defp update_row(repo, agent_uid, changes) do
    {state_changed?, changes} = Keyword.pop(changes, :state_changed?, false)

    query =
      from worker in AgentWorker,
        where: worker.agent_uid == ^agent_uid,
        update: [set: ^changes],
        select: worker

    query =
      if state_changed?,
        do: update(query, set: [state_changed_at: fragment("now()")]),
        else: query

    query =
      if Keyword.get(changes, :state) == "ready",
        do:
          update(query, [worker],
            set: [
              last_worker_heartbeat_at: fragment("now()"),
              instance_seen_at: fragment("coalesce(?, now())", worker.instance_seen_at)
            ]
          ),
        else: query

    case repo.update_all(query, []) do
      {1, [worker]} -> {:ok, worker}
      {0, []} -> {:error, :unknown_worker}
    end
  end

  defp lock_by_route(repo, route) do
    AgentWorker
    |> where([worker], worker.transport_route == ^route)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp close_replaced_route(_agent_uid, nil, _reason), do: :ok

  defp close_replaced_route(agent_uid, route, reason),
    do: WorkerRoute.close_connection(agent_uid, route, reason)

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
