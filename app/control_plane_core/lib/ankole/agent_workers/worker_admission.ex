defmodule Ankole.AgentWorkers.WorkerAdmission do
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
  require Ash.Query

  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerRoute

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
  @spec handle_worker_heartbeat(FabricProto.WorkerHeartbeat.t(), auth()) ::
          {:ok, AgentWorker.t()} | {:error, term()}
  def handle_worker_heartbeat(%FabricProto.WorkerHeartbeat{} = heartbeat, auth) do
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

  @doc "Expires a connection after 60 seconds without a heartbeat, on any control-plane node."
  @spec expire_connection(String.t()) :: :ok | {:error, term()}
  def expire_connection(agent_uid) do
    with {:ok, disconnected} <-
           Repo.transact(fn repo ->
             worker =
               repo.one(
                 from(w in AgentWorker,
                   where: w.agent_uid == ^agent_uid and w.state in ^@connected_states,
                   where: not is_nil(w.transport_route),
                   where:
                     is_nil(w.last_worker_heartbeat_at) or
                       w.last_worker_heartbeat_at <=
                         fragment("clock_timestamp() - interval '60 seconds'"),
                   lock: "FOR UPDATE"
                 ),
                 lock_identity: {"agent_workers", agent_uid}
               )

             if worker,
               do: disconnect(repo, worker, "heartbeat_timeout"),
               else: {:ok, nil}
           end) do
      if disconnected do
        {worker, route} = disconnected
        AgentWorkers.notify_changed(worker.agent_uid)
        WorkerRoute.close_connection(worker.agent_uid, route, :worker_heartbeat_timeout)
      end

      :ok
    end
  end

  defp admit_in_tx(repo, agent_uid, generation, route, attrs) do
    case AgentWorkers.lock_in_tx(repo, agent_uid) do
      %AgentWorker{state: state, generation: ^generation} = worker when state in @join_states ->
        replaced_route = if worker.transport_route not in [nil, route], do: worker.transport_route

        with {:ok, worker} <-
               Ankole.Ash.update(worker, :admit, %{
                 generation: generation,
                 incarnation_id: attrs.incarnation_id,
                 transport_route: route,
                 capacity: attrs.capacity
               }) do
          {:ok, %{worker: worker, replaced_route: replaced_route}}
        else
          {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} ->
            {:error, :worker_incarnation_active}

          {:error, _reason} = error ->
            error
        end

      %AgentWorker{} ->
        {:error, :stale_worker_generation}

      nil ->
        {:error, :unknown_worker}
    end
  end

  # One conditional UPDATE: the row must still be connected on this route
  # with this incarnation, so a message from an old connection or process
  # changes nothing.
  #
  # A capacity change wakes drivers that are waiting for a slot.
  defp renew(agent_uid, incarnation_id, route, changes) do
    result =
      Repo.transact(fn repo ->
        previous = AgentWorkers.lock_in_tx(repo, agent_uid)

        input =
          changes
          |> Map.take([:capacity, :load])
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.merge(%{route: route, incarnation: incarnation_id})

        case AgentWorker
             |> Ash.Query.filter(agent_uid == ^agent_uid)
             |> Ankole.Ash.bulk_update(:heartbeat, input,
               strategy: [:atomic],
               return_records?: true,
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success, records: [worker]} ->
            {:ok, {worker, previous.capacity != worker.capacity}}

          %Ash.BulkResult{status: :success, records: []} ->
            {:error, :stale_transport_route}

          %Ash.BulkResult{errors: errors} ->
            {:error, Ash.Error.to_error_class(errors)}
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

  defp mark_draining(_repo, %AgentWorker{} = worker, reason) do
    Ankole.Ash.update(worker, :drain, %{drain_reason: worker.drain_reason || reason})
  end

  # A draining connection loses its route without reopening placement.
  defp disconnect(_repo, %AgentWorker{} = worker, _reason) do
    route = worker.transport_route

    with {:ok, updated} <- Ankole.Ash.update(worker, :disconnect, %{}),
         do: {:ok, {updated, route}}
  end

  defp lock_by_route(repo, route) do
    AgentWorker
    |> where([worker], worker.transport_route == ^route)
    |> lock("FOR UPDATE")
    |> repo.lock_all("agent_workers", :agent_uid)
    |> List.first()
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
