defmodule Ankole.SignalsGateway.ActorRuntime.WorkerAdmission do
  @moduledoc """
  Worker admission boundary for authenticated actor lane lifecycle messages.

  Every worker lifecycle message (ready / heartbeat / capacity) lands here after
  the transport has authenticated the route, and gets projected into the
  UNLOGGED `agent_computer_workers` registry — the scheduler's single source of
  worker liveness. The registry is rebuilt from authenticated worker heartbeats
  after database recovery. Lifecycle messages must come from the authenticated
  worker id and route and process incarnation the projection owns. When a worker
  dies, is replaced, or its route breaks, all live deliveries are superseded and
  its assignments released, but the underlying actor event rows stay open so
  the scheduler can simply retry them.
  """

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool

  @ready_worker_status "ready"
  # Only "ready"/"draining" workers can be made stale or block a duplicate claim;
  # already-stale/stopped rows are inert and handled by the TTL reaper instead.
  @stale_worker_statuses ~w(ready draining)
  @worker_stale_after_seconds 60
  @stale_worker_ttl_seconds 3_600

  @doc """
  Lists worker registry rows for operator-facing views.

  The registry is owned by RuntimeFabric lifecycle messages; this read path only
  projects what those messages have recorded.
  """
  @spec list_workers() :: [AgentComputerWorker.t()]
  def list_workers do
    AgentComputerWorker
    |> order_by([worker], desc: worker.inserted_at)
    |> Repo.all()
  end

  @doc """
  Admits an authenticated worker-ready message.

  Worker readiness is accepted only from the route that the transport already
  authenticated. The worker payload names the stable worker id and one concrete
  process incarnation; the route proves where replies should be sent.
  """
  @spec admit_worker_ready(
          FabricProto.AgentComputerWorkerReady.t(),
          String.t() | map()
        ) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def admit_worker_ready(
        %FabricProto.AgentComputerWorkerReady{} = worker_ready,
        authenticated_route
      ) do
    with {:ok, auth} <- authenticated_route(authenticated_route),
         {:ok, attrs} <- worker_ready_attrs(worker_ready, auth.route),
         :ok <- authenticated_worker_matches(auth, attrs.worker_id) do
      record_worker_ready(attrs, auth.route)
    end
  end

  @doc """
  Records a worker-ready projection.

  Admitted workers already match the one RuntimeFabric protocol version. The
  projection records product/runtime observability, liveness, route, capacity,
  and load; it does not negotiate per-worker features.
  """
  @spec record_worker_ready(map(), String.t() | nil) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def record_worker_ready(attrs, route \\ nil) when is_map(attrs) do
    now = Map.get(attrs, :now) || DateTime.utc_now(:microsecond)

    attrs =
      attrs
      |> Map.put_new(:status, @ready_worker_status)
      |> Map.put_new(:capacity, %{})
      |> Map.put_new(:load, %{})
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:started_at, now)
      |> Map.put(:last_worker_heartbeat_at, now)
      |> Ankole.Attrs.maybe_put(:transport_route, route)

    result =
      Repo.transact(fn repo ->
        with :ok <- worker_route_available(repo, attrs) do
          case lock_worker_by_id(repo, attrs.worker_id) do
            %AgentComputerWorker{} = worker ->
              replaced_route =
                if worker.incarnation_id != attrs.incarnation_id,
                  do: worker.transport_route,
                  else: nil

              with {:ok, worker} <- refresh_worker_ready(repo, worker, attrs, now) do
                {:ok, {worker, replaced_route}}
              end

            nil ->
              with {:ok, worker} <- insert_worker_projection(repo, attrs) do
                {:ok, {worker, nil}}
              end
          end
        end
      end)

    case result do
      {:ok, {%AgentComputerWorker{} = worker, replaced_route}} ->
        fail_pending_rpcs(replaced_route, :worker_incarnation_replaced)
        Ankole.RuntimeEvents.Scheduler.hydrate()
        {:ok, worker}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Records an authenticated worker heartbeat projection.

  A heartbeat carries the complete live worker snapshot. It renews the worker's
  lease and can rebuild a missing UNLOGGED projection after database recovery.
  An existing projection is updated only if its route and incarnation still
  match, so an old process cannot replace the current worker.
  """
  @spec handle_worker_heartbeat(FabricProto.AgentComputerWorkerHeartbeat.t(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def handle_worker_heartbeat(
        %FabricProto.AgentComputerWorkerHeartbeat{} = worker_heartbeat,
        authenticated_route
      ) do
    with {:ok, auth} <- authenticated_route(authenticated_route),
         {:ok, attrs} <- worker_heartbeat_attrs(worker_heartbeat, auth.route),
         :ok <- authenticated_worker_matches(auth, attrs.worker_id) do
      now = DateTime.utc_now(:microsecond)
      attrs = Map.put(attrs, :last_worker_heartbeat_at, now)

      update_worker_projection(
        attrs.worker_id,
        attrs.incarnation_id,
        auth.route,
        Map.take(attrs, [:version, :capacity, :load, :metadata, :last_worker_heartbeat_at]),
        attrs
        |> Map.put(:status, @ready_worker_status)
        |> Map.put(:started_at, now)
      )
    end
  end

  @doc """
  Records an authenticated worker capacity projection.

  Capacity updates feed `WorkerPool` placement decisions (free turn slots). Like
  heartbeats, this also refreshes the lease and is identity/route fenced so a
  stale connection cannot rewrite a live worker's capacity.
  """
  @spec handle_worker_capacity(FabricProto.AgentComputerWorkerCapacity.t(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def handle_worker_capacity(
        %FabricProto.AgentComputerWorkerCapacity{} = worker_capacity,
        authenticated_route
      ) do
    with {:ok, auth} <- authenticated_route(authenticated_route),
         {:ok, worker_id} <- required_text(worker_capacity.worker_id, "worker_id"),
         {:ok, incarnation_id} <-
           required_text(worker_capacity.incarnation_id, "incarnation_id"),
         :ok <- authenticated_worker_matches(auth, worker_id) do
      update_worker_projection(worker_id, incarnation_id, auth.route, %{
        capacity: %{
          "max_turns" => worker_capacity.max_turns,
          "available_turn_slots" => worker_capacity.available_turn_slots
        },
        load: %{"active_turns" => worker_capacity.active_turns},
        last_worker_heartbeat_at: DateTime.utc_now(:microsecond)
      })
    end
  end

  @doc """
  Removes an authenticated worker from placement while its active turns drain.

  The worker, its assignments, and its activations keep their route fences, so
  terminal writes and RPC acknowledgements remain valid until process exit.
  """
  @spec handle_control_shutdown(FabricProto.ControlShutdown.t(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def handle_control_shutdown(
        %FabricProto.ControlShutdown{} = control_shutdown,
        authenticated_route
      ) do
    with {:ok, auth} <- authenticated_route(authenticated_route),
         {:ok, reason} <- required_text(control_shutdown.reason, "reason") do
      now = DateTime.utc_now(:microsecond)

      Repo.transact(fn repo ->
        case worker_by_route(repo, auth.route) do
          %AgentComputerWorker{} = worker ->
            with :ok <- authenticated_worker_matches(auth, worker.worker_id),
                 :ok <- worker_can_drain(worker),
                 {:ok, worker} <- mark_worker_draining(repo, worker, reason),
                 :ok <- mark_worker_fences_draining(repo, worker, now) do
              {:ok, worker}
            end

          nil ->
            {:error, :worker_not_ready}
        end
      end)
    end
  end

  @doc """
  Marks the worker that owns a broken route stale and releases its in-flight work.
  """
  @spec mark_route_unusable(String.t() | nil, term()) :: :ok | {:ok, term()} | {:error, term()}
  def mark_route_unusable(route, reason)
      when is_binary(route) and reason in [:unknown_route, :socket_closed] do
    now = DateTime.utc_now(:microsecond)

    result =
      Repo.transact(fn repo ->
        case worker_by_route(repo, route) do
          %AgentComputerWorker{} = worker ->
            with {:ok, _worker} <-
                   stale_worker_transition(repo, worker, now, Atom.to_string(reason)) do
              {:ok, :marked_stale}
            end

          nil ->
            {:ok, :route_not_registered}
        end
      end)

    if match?({:ok, _result}, result), do: Broker.fail_pending_rpcs(route, reason)
    result
  end

  def mark_route_unusable(_route, _reason), do: :ok

  @doc """
  Marks every ready route stale when the RuntimeFabric router itself stops.

  A router restart invalidates the ZeroMQ route identities held in worker
  projections. Workers may re-admit themselves, and replacement workers can be
  scheduled immediately, but stale route rows must not keep receiving turns.
  """
  @spec mark_all_routes_unusable(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def mark_all_routes_unusable(reason) do
    now = DateTime.utc_now(:microsecond)
    reason = normalize_reason(reason)

    result =
      Repo.transact(fn repo ->
        AgentComputerWorker
        |> where([worker], worker.status in ^@stale_worker_statuses)
        |> lock("FOR UPDATE")
        |> repo.all()
        |> Enum.map(&stale_worker_transition(repo, &1, now, reason))
        |> Ankole.Attrs.collect_results()
      end)

    case result do
      {:ok, workers} ->
        Enum.each(workers, &fail_pending_rpcs(&1.transport_route, reason))
        {:ok, length(workers)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    now = DateTime.utc_now(:microsecond)

    AgentComputerWorker
    |> where([worker], worker.status in ["ready", "draining", "stale", "stopped"])
    |> Repo.all()
    |> Enum.map(&worker_runtime_event(&1, now))
  end

  @doc false
  @spec mark_worker_stale_if_due(String.t(), keyword()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def mark_worker_stale_if_due(worker_id, opts \\ []) when is_binary(worker_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @worker_stale_after_seconds)

    result =
      Repo.transact(fn repo ->
        case lock_worker_by_id(repo, worker_id) do
          %AgentComputerWorker{} = worker ->
            cond do
              worker.status not in @stale_worker_statuses ->
                {:error, :worker_not_due}

              not worker_stale_due?(worker, now, stale_after_seconds) ->
                {:error, :worker_not_due}

              true ->
                stale_worker_transition(repo, worker, now, "heartbeat_timeout")
            end

          nil ->
            {:error, :worker_not_found}
        end
      end)

    case result do
      {:ok, %AgentComputerWorker{transport_route: route}} ->
        fail_pending_rpcs(route, :heartbeat_timeout)
        result

      _result ->
        result
    end
  end

  @doc false
  @spec delete_worker_if_due(String.t(), keyword()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def delete_worker_if_due(worker_id, opts \\ []) when is_binary(worker_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    ttl_seconds = Keyword.get(opts, :stale_worker_ttl_seconds, @stale_worker_ttl_seconds)

    Repo.transact(fn repo ->
      case lock_worker_by_id(repo, worker_id) do
        %AgentComputerWorker{} = worker ->
          cond do
            worker.status not in ["stale", "stopped"] ->
              {:error, :worker_not_due}

            not worker_delete_due?(worker, now, ttl_seconds) ->
              {:error, :worker_not_due}

            true ->
              repo.delete(worker)
          end

        nil ->
          {:error, :worker_not_found}
      end
    end)
  end

  # Updates lifecycle projections only when the worker still owns the transport
  # route and incarnation. Authenticated traffic from that same process proves
  # it is reachable again, so a stale projection may re-enter the ready pool.
  # The stale transition already released assignments and superseded deliveries;
  # re-admission never restores those fences or accepts late Turn writes.
  defp update_worker_projection(worker_id, incarnation_id, route, attrs, missing_attrs \\ nil) do
    result =
      Repo.transact(fn repo ->
        case lock_worker_by_id(repo, worker_id) do
          %AgentComputerWorker{} = worker ->
            with :ok <- worker_route_matches(worker, route),
                 :ok <- worker_incarnation_matches(worker, incarnation_id) do
              worker
              |> AgentComputerWorker.changeset(
                revalidate_authenticated_stale_worker(worker, attrs)
              )
              |> repo.update()
              |> notify_worker_stale_deadline(repo)
            end

          nil when is_map(missing_attrs) ->
            with :ok <- worker_route_available(repo, missing_attrs),
                 {:ok, worker} <- insert_worker_projection(repo, missing_attrs) do
              {:ok, {:admitted, worker}}
            end

          nil ->
            {:error, :worker_not_ready}
        end
      end)

    case result do
      {:ok, {:admitted, worker}} ->
        Ankole.RuntimeEvents.Scheduler.hydrate()
        {:ok, worker}

      result ->
        result
    end
  end

  defp revalidate_authenticated_stale_worker(
         %AgentComputerWorker{status: "stale"},
         attrs
       ) do
    Map.merge(attrs, %{status: @ready_worker_status, stopped_at: nil, stop_reason: nil})
  end

  defp revalidate_authenticated_stale_worker(_worker, attrs), do: attrs

  defp refresh_worker_ready(repo, %AgentComputerWorker{} = worker, attrs, now) do
    replacement? = worker.incarnation_id != attrs.incarnation_id

    with :ok <- maybe_release_replaced_worker(repo, worker, attrs.incarnation_id, now) do
      attrs =
        if replacement? do
          attrs
        else
          Map.put(attrs, :started_at, worker.started_at || attrs.started_at)
        end

      attrs = Map.merge(attrs, %{stopped_at: nil, stop_reason: nil})

      worker
      |> AgentComputerWorker.changeset(attrs)
      |> repo.update()
      |> notify_worker_stale_deadline(repo)
    end
  end

  defp insert_worker_projection(repo, attrs) do
    %AgentComputerWorker{}
    |> AgentComputerWorker.changeset(attrs)
    |> repo.insert()
    |> notify_worker_stale_deadline(repo)
  end

  defp maybe_release_replaced_worker(
         _repo,
         %AgentComputerWorker{incarnation_id: incarnation_id},
         incarnation_id,
         _now
       ),
       do: :ok

  defp maybe_release_replaced_worker(repo, %AgentComputerWorker{} = worker, _incarnation_id, now) do
    release_worker_fences(repo, worker, now, "worker_incarnation_replaced")
  end

  # Ensures a live transport route belongs to one worker projection. ROUTER
  # identities are the address used by delivery, so sharing them would break
  # mandatory-send failure handling.
  defp worker_route_available(repo, %{worker_id: worker_id, transport_route: route})
       when is_binary(route) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> where([worker], worker.worker_id != ^worker_id)
    |> where([worker], worker.status in ^@stale_worker_statuses)
    |> repo.exists?()
    |> case do
      true -> {:error, :duplicate_worker_route}
      false -> :ok
    end
  end

  defp worker_route_available(_repo, _attrs), do: :ok

  # Verifies that a lifecycle message still belongs to the admitted route.
  defp worker_route_matches(%AgentComputerWorker{} = worker, route) do
    cond do
      worker.transport_route != route ->
        {:error, :stale_transport_route}

      true ->
        :ok
    end
  end

  defp worker_incarnation_matches(
         %AgentComputerWorker{incarnation_id: incarnation_id},
         incarnation_id
       ),
       do: :ok

  defp worker_incarnation_matches(%AgentComputerWorker{}, _incarnation_id),
    do: {:error, :stale_worker_incarnation}

  defp worker_by_route(repo, route) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp worker_can_drain(%AgentComputerWorker{status: status})
       when status in ["ready", "draining"],
       do: :ok

  defp worker_can_drain(%AgentComputerWorker{}), do: {:error, :worker_not_ready}

  defp mark_worker_draining(repo, worker, reason) do
    capacity = Map.put(worker.capacity || %{}, "available_turn_slots", 0)
    metadata = Map.put(worker.metadata || %{}, "drain_reason", reason)

    worker
    |> AgentComputerWorker.changeset(%{
      status: "draining",
      capacity: capacity,
      metadata: metadata
    })
    |> repo.update()
    |> notify_worker_stale_deadline(repo)
  end

  defp mark_worker_fences_draining(repo, worker, now) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.worker_id == ^worker.worker_id)
    |> where([assignment], assignment.status == "assigned")
    |> repo.update_all(set: [status: "draining", updated_at: now])

    ActorSessionActivation
    |> where([activation], activation.assigned_worker_id == ^worker.worker_id)
    |> where([activation], activation.status in ["starting", "active"])
    |> repo.update_all(set: [status: "draining", updated_at: now])

    :ok
  end

  defp lock_worker_by_id(repo, worker_id) do
    AgentComputerWorker
    |> where([worker], worker.worker_id == ^worker_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Moves a worker out of service and releases every runtime fence that points
  # at it. The actor event rows stay open, so the next scheduler pass can retry
  # without changing the user-visible work.
  defp stale_worker_transition(repo, %AgentComputerWorker{} = worker, now, reason) do
    with {:ok, worker} <- mark_worker_stale(repo, worker, now, reason),
         :ok <- release_worker_fences(repo, worker, now, reason),
         :ok <- notify_worker_delete_deadline(repo, worker) do
      {:ok, worker}
    end
  end

  defp release_worker_fences(repo, %AgentComputerWorker{} = worker, now, reason) do
    delivery_actor_keys = worker_actor_keys(repo, worker)

    with {:ok, %{actor_keys: activation_actor_keys}} <-
           TurnLifecycle.fail_worker_activations_in_tx(repo, worker.worker_id, now, reason),
         {_delivery_count, _rows} <-
           supersede_live_deliveries_for_worker(repo, worker, now, reason),
         {_assignment_count, _rows} <- WorkerPool.release_assignments_for_worker(repo, worker),
         actor_keys = merge_actor_keys(delivery_actor_keys, activation_actor_keys),
         :ok <- notify_actor_keys(repo, actor_keys, now) do
      :ok
    end
  end

  defp mark_worker_stale(repo, %AgentComputerWorker{} = worker, now, reason) do
    worker
    |> AgentComputerWorker.changeset(%{
      status: "stale",
      stopped_at: now,
      stop_reason: reason
    })
    |> repo.update()
  end

  # The activation failure path should normally handle accepted deliveries, but
  # worker recovery must still clear every runtime fence owned by the dead
  # process. Otherwise a lost or drifted activation can leave the actor queue
  # permanently blocked behind an unusable delivery.
  defp supersede_live_deliveries_for_worker(
         repo,
         %AgentComputerWorker{} = worker,
         now,
         reason
       ) do
    ActorEventDelivery
    |> where([delivery], delivery.worker_id == ^worker.worker_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end

  defp worker_actor_keys(repo, %AgentComputerWorker{} = worker) do
    ActorEventDelivery
    |> where([delivery], delivery.worker_id == ^worker.worker_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> select([delivery], %{agent_uid: delivery.agent_uid, session_id: delivery.session_id})
    |> distinct(true)
    |> repo.all()
  end

  defp merge_actor_keys(left, right) do
    (left ++ right)
    |> Enum.uniq_by(&{&1.agent_uid, &1.session_id})
  end

  defp notify_actor_keys(repo, actor_keys, now) do
    actor_keys
    |> Enum.map(fn actor_key ->
      RuntimeEvents.notify_actor_session_ready(
        repo,
        actor_key.agent_uid,
        actor_key.session_id,
        now
      )
    end)
    |> collect_notification_results()
  end

  defp notify_worker_stale_deadline({:ok, %AgentComputerWorker{} = worker}, repo) do
    with :ok <-
           RuntimeEvents.notify_worker_deadline(repo, worker,
             stale_at: worker_stale_at(worker, DateTime.utc_now(:microsecond))
           ) do
      {:ok, worker}
    end
  end

  defp notify_worker_stale_deadline({:error, _reason} = error, _repo), do: error

  defp notify_worker_delete_deadline(repo, %AgentComputerWorker{} = worker) do
    RuntimeEvents.notify_worker_deadline(repo, worker, delete_at: worker_delete_at(worker))
  end

  defp worker_runtime_event(%AgentComputerWorker{} = worker, now) do
    {RuntimeEvents.worker_deadline_channel(),
     %{
       "worker_id" => worker.worker_id,
       "transport_route" => worker.transport_route,
       "stale_at" =>
         if(worker.status in @stale_worker_statuses,
           do: RuntimeEvents.encode_datetime(worker_stale_at(worker, now))
         ),
       "delete_at" =>
         if(worker.status in ["stale", "stopped"],
           do: RuntimeEvents.encode_datetime(worker_delete_at(worker))
         )
     }}
  end

  defp worker_stale_due?(%AgentComputerWorker{} = worker, now, stale_after_seconds) do
    heartbeat_at = worker.last_worker_heartbeat_at

    is_nil(heartbeat_at) or
      DateTime.compare(heartbeat_at, DateTime.add(now, -stale_after_seconds, :second)) != :gt
  end

  defp worker_delete_due?(%AgentComputerWorker{} = worker, now, ttl_seconds) do
    case worker_delete_base_at(worker) do
      %DateTime{} = base_at ->
        DateTime.compare(base_at, DateTime.add(now, -ttl_seconds, :second)) != :gt

      nil ->
        false
    end
  end

  defp worker_stale_at(
         %AgentComputerWorker{last_worker_heartbeat_at: %DateTime{} = heartbeat_at},
         _now
       ),
       do: DateTime.add(heartbeat_at, @worker_stale_after_seconds, :second)

  defp worker_stale_at(%AgentComputerWorker{}, now), do: now

  defp worker_delete_at(%AgentComputerWorker{} = worker) do
    case worker_delete_base_at(worker) do
      %DateTime{} = base_at -> DateTime.add(base_at, @stale_worker_ttl_seconds, :second)
      nil -> nil
    end
  end

  defp worker_delete_base_at(%AgentComputerWorker{} = worker),
    do: worker.stopped_at || worker.last_worker_heartbeat_at

  # Normalizes the transport boundary into a plain route string. Tests may pass
  # the route directly; production passes a small authenticated route map.
  defp authenticated_route(route) when is_binary(route) and route != "",
    do: {:ok, %{route: route, worker_id: nil}}

  defp authenticated_route(%{authenticated?: true, transport_route: route, worker_id: worker_id})
       when is_binary(route) and route != "" and is_binary(worker_id) and worker_id != "",
       do: {:ok, %{route: route, worker_id: worker_id}}

  defp authenticated_route(%{authenticated?: true, transport_route: route})
       when is_binary(route) and route != "",
       do: {:ok, %{route: route, worker_id: nil}}

  defp authenticated_route(%{
         "authenticated" => true,
         "transport_route" => route,
         "worker_id" => worker_id
       })
       when is_binary(route) and route != "" and is_binary(worker_id) and worker_id != "",
       do: {:ok, %{route: route, worker_id: worker_id}}

  defp authenticated_route(%{"authenticated" => true, "transport_route" => route})
       when is_binary(route) and route != "",
       do: {:ok, %{route: route, worker_id: nil}}

  defp authenticated_route(_route), do: {:error, :unauthenticated_worker_route}

  # When the transport did not authenticate an identity (ZAP-disabled test path,
  # worker_id == nil) there is nothing to cross-check, so accept. When it did,
  # the payload's worker_id must equal the proven one — otherwise a worker is
  # claiming to be someone else and the message is rejected.
  defp authenticated_worker_matches(%{worker_id: nil}, _worker_id), do: :ok

  defp authenticated_worker_matches(%{worker_id: authenticated_worker_id}, worker_id)
       when authenticated_worker_id == worker_id,
       do: :ok

  defp authenticated_worker_matches(_auth, _worker_id),
    do: {:error, :worker_auth_identity_mismatch}

  # Extracts only the data needed to place protocol-compatible workers. Runtime
  # and product version stay as observability metadata, not scheduling axes.
  defp worker_ready_attrs(%FabricProto.AgentComputerWorkerReady{} = worker_ready, route) do
    with {:ok, worker_id} <- required_text(worker_ready.worker_id, "worker_id"),
         {:ok, incarnation_id} <- required_text(worker_ready.incarnation_id, "incarnation_id"),
         {:ok, runtime} <- required_text(worker_ready.runtime, "runtime"),
         {:ok, version} <- required_text(worker_ready.version, "version") do
      {:ok,
       %{
         worker_id: worker_id,
         incarnation_id: incarnation_id,
         status: @ready_worker_status,
         version: version,
         capacity: %{
           "max_turns" => worker_ready.max_turns,
           "available_turn_slots" => worker_ready.available_turn_slots
         },
         load: %{},
         transport_route: route,
         metadata: %{"runtime" => runtime}
       }}
    end
  end

  defp worker_heartbeat_attrs(
         %FabricProto.AgentComputerWorkerHeartbeat{} = worker_heartbeat,
         route
       ) do
    with {:ok, worker_id} <- required_text(worker_heartbeat.worker_id, "worker_id"),
         {:ok, incarnation_id} <-
           required_text(worker_heartbeat.incarnation_id, "incarnation_id"),
         {:ok, runtime} <- required_text(worker_heartbeat.runtime, "runtime"),
         {:ok, version} <- required_text(worker_heartbeat.version, "version") do
      {:ok,
       %{
         worker_id: worker_id,
         incarnation_id: incarnation_id,
         version: version,
         capacity: %{
           "max_turns" => worker_heartbeat.max_turns,
           "available_turn_slots" => worker_heartbeat.available_turn_slots
         },
         load: %{"active_turns" => worker_heartbeat.active_turns},
         transport_route: route,
         metadata: %{"runtime" => runtime}
       }}
    end
  end

  defp required_text(value, key) do
    case value do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  defp fail_pending_rpcs(route, reason) when is_binary(route),
    do: Broker.fail_pending_rpcs(route, reason)

  defp fail_pending_rpcs(_route, _reason), do: :ok

  defp collect_notification_results(results) do
    Enum.reduce_while(results, :ok, fn
      :ok, :ok -> {:cont, :ok}
      {:error, _reason} = error, :ok -> {:halt, error}
    end)
  end
end
