defmodule Ankole.ActorRuntime.WorkerAdmission do
  @moduledoc """
  Worker admission boundary for authenticated Actor Bus lifecycle messages.

  Every worker lifecycle message (ready / heartbeat / capacity) lands here after
  the transport has authenticated the route, and gets projected into the durable
  `agent_computer_worker` table — the scheduler's single source of worker
  liveness. Two invariants drive most of the logic in this module:

    * Identity fencing: the message must come from the route+instance the worker
      currently owns. A reconnected worker gets a fresh `worker_instance_id`, so
      a stale connection (or an old process) can never refresh or keep alive a
      projection that has moved on.
    * Safe staleness: when a worker dies or its route breaks, its created/sent
      deliveries are superseded and its assignments released, but the underlying
      actor input rows stay open so the scheduler can simply retry them — worker
      death never loses user-visible work.
  """

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.Repo

  @ready_worker_status "ready"
  # Only "ready"/"draining" workers can be made stale or block a duplicate claim;
  # already-stale/stopped rows are inert and handled by the TTL reaper instead.
  @stale_worker_statuses ~w(ready draining)

  @doc """
  Admits an authenticated worker-ready message.

  Worker readiness is accepted only from the route that the transport already
  authenticated. The worker payload names the instance; the route proves where
  replies should be sent.
  """
  @spec admit_worker_ready(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def admit_worker_ready(worker_ready, authenticated_route) when is_map(worker_ready) do
    with {:ok, auth} <- authenticated_route(authenticated_route),
         {:ok, attrs} <- worker_ready_attrs(worker_ready, auth.route),
         :ok <- authenticated_worker_matches(auth, attrs.worker_id) do
      record_worker_ready(attrs, auth.route)
    end
  end

  @doc """
  Records a worker-ready projection.

  Workers are homogeneous because they boot from the same image. The projection
  therefore records liveness, route, version, capacity, and load, but it does
  not negotiate per-worker features.
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
      |> maybe_put(:transport_route, route)

    # Upsert keyed on worker_id: a worker restarting under the same stable id
    # overwrites its prior projection (new instance id, route, capacity, fresh
    # lease) in one statement, rather than racing an insert against a delete of
    # the old row. The replace list is every field a re-ready should refresh.
    Repo.transact(fn repo ->
      with :ok <- worker_instance_available(repo, attrs),
           :ok <- worker_route_available(repo, attrs) do
        %AgentComputerWorker{}
        |> AgentComputerWorker.changeset(attrs)
        |> repo.insert(
          on_conflict:
            {:replace,
             [
               :worker_instance_id,
               :status,
               :version,
               :capacity,
               :load,
               :transport_route,
               :last_worker_heartbeat_at,
               :started_at,
               :stopped_at,
               :stop_reason,
               :metadata,
               :updated_at
             ]},
          conflict_target: [:worker_id],
          returning: true
        )
      end
    end)
  end

  @doc """
  Records an authenticated worker heartbeat projection.

  A heartbeat renews the worker's lease (its `last_worker_heartbeat_at`), which is
  the clock the watchdog reads to decide staleness. It is accepted only if the
  authenticated identity matches and the worker still owns its instance+route, so
  heartbeats from a previous process cannot keep a superseded worker alive.
  """
  @spec handle_worker_heartbeat(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def handle_worker_heartbeat(worker_heartbeat, authenticated_route)
      when is_map(worker_heartbeat) do
    with {:ok, auth} <- authenticated_route(authenticated_route),
         {:ok, worker_id} <- fetch_required_text(worker_heartbeat, "worker_id"),
         :ok <- authenticated_worker_matches(auth, worker_id),
         {:ok, worker_instance_id} <- fetch_required_text(worker_heartbeat, "worker_instance_id") do
      update_worker_projection(worker_id, worker_instance_id, auth.route, %{
        last_worker_heartbeat_at: DateTime.utc_now(:microsecond),
        load: fetch_map(worker_heartbeat, "load_json") || %{}
      })
    end
  end

  @doc """
  Records an authenticated worker capacity projection.

  Capacity updates feed `WorkerPool` placement decisions (free turn slots). Like
  heartbeats, this also refreshes the lease and is identity/route fenced so a
  stale connection cannot rewrite a live worker's capacity.
  """
  @spec handle_worker_capacity(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def handle_worker_capacity(worker_capacity, authenticated_route) when is_map(worker_capacity) do
    with {:ok, auth} <- authenticated_route(authenticated_route),
         {:ok, worker_id} <- fetch_required_text(worker_capacity, "worker_id"),
         :ok <- authenticated_worker_matches(auth, worker_id),
         {:ok, worker_instance_id} <- fetch_required_text(worker_capacity, "worker_instance_id") do
      # Prefer the structured capacity map; fall back to the scalar
      # available_turn_slots field for older workers that don't send capacity_json.
      capacity =
        worker_capacity
        |> fetch_map("capacity_json")
        |> case do
          %{} = capacity ->
            capacity

          _value ->
            %{"available_turn_slots" => fetch_int(worker_capacity, "available_turn_slots") || 0}
        end

      update_worker_projection(worker_id, worker_instance_id, auth.route, %{
        capacity: capacity,
        load: fetch_map(worker_capacity, "load_json") || %{},
        last_worker_heartbeat_at: DateTime.utc_now(:microsecond)
      })
    end
  end

  @doc """
  Marks the worker that owns a broken route stale and releases its in-flight work.
  """
  @spec mark_route_unusable(String.t() | nil, term()) :: :ok | {:ok, term()} | {:error, term()}
  def mark_route_unusable(route, reason)
      when is_binary(route) and reason in [:unknown_route, :socket_closed] do
    now = DateTime.utc_now(:microsecond)

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
  end

  def mark_route_unusable(_route, _reason), do: :ok

  @doc """
  Marks ready or draining workers stale after their heartbeat lease expires.
  """
  @spec mark_stale_workers(module(), DateTime.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def mark_stale_workers(repo, now, stale_after_seconds) do
    cutoff = DateTime.add(now, -stale_after_seconds, :second)

    workers =
      AgentComputerWorker
      |> where([worker], worker.status in ^@stale_worker_statuses)
      |> where(
        [worker],
        is_nil(worker.last_worker_heartbeat_at) or worker.last_worker_heartbeat_at <= ^cutoff
      )
      |> lock("FOR UPDATE")
      |> repo.all()

    workers
    |> Enum.map(fn worker ->
      with {:ok, worker} <- stale_worker_transition(repo, worker, now, "heartbeat_timeout") do
        {:ok, worker}
      end
    end)
    |> collect_results()
    |> case do
      {:ok, workers} -> {:ok, length(workers)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Deletes stale worker projections after the retention TTL.
  """
  @spec delete_expired_stale_workers(module(), DateTime.t(), non_neg_integer()) ::
          {non_neg_integer(), nil | [term()]}
  def delete_expired_stale_workers(repo, now, ttl_seconds) do
    cutoff = DateTime.add(now, -ttl_seconds, :second)

    AgentComputerWorker
    |> where([worker], worker.status in ["stale", "stopped"])
    |> where(
      [worker],
      worker.last_worker_heartbeat_at <= ^cutoff or
        (is_nil(worker.last_worker_heartbeat_at) and worker.stopped_at <= ^cutoff)
    )
    |> repo.delete_all()
  end

  # Updates heartbeat and capacity only when the worker still owns both the
  # instance id and transport route. This prevents an old connection from
  # refreshing a projection after the worker has restarted.
  defp update_worker_projection(worker_id, worker_instance_id, route, attrs) do
    Repo.transact(fn repo ->
      case repo.get_by(AgentComputerWorker, worker_id: worker_id) do
        %AgentComputerWorker{} = worker ->
          with :ok <- worker_route_matches(worker, worker_instance_id, route) do
            worker
            |> AgentComputerWorker.changeset(attrs)
            |> repo.update()
          end

        nil ->
          {:error, :worker_not_ready}
      end
    end)
  end

  # Ensures one live instance id cannot be claimed by two worker ids. A repeated
  # ready from the same worker id is an update; a different worker id is stale or
  # misconfigured.
  defp worker_instance_available(repo, %{worker_id: worker_id, worker_instance_id: instance_id})
       when is_binary(instance_id) do
    AgentComputerWorker
    |> where([worker], worker.worker_instance_id == ^instance_id)
    |> where([worker], worker.worker_id != ^worker_id)
    |> where([worker], worker.status in ^@stale_worker_statuses)
    |> repo.exists?()
    |> case do
      true -> {:error, :duplicate_worker_instance}
      false -> :ok
    end
  end

  defp worker_instance_available(_repo, _attrs), do: :ok

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

  # Verifies that a lifecycle message still belongs to the admitted worker
  # instance. Heartbeats from a previous process must not keep new work alive.
  defp worker_route_matches(%AgentComputerWorker{} = worker, worker_instance_id, route) do
    cond do
      worker.worker_instance_id != worker_instance_id ->
        {:error, :stale_worker_instance}

      worker.transport_route != route ->
        {:error, :stale_transport_route}

      true ->
        :ok
    end
  end

  defp worker_by_route(repo, route) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Moves a worker out of service and releases every runtime fence that points
  # at it. The actor input rows stay open, so the next scheduler pass can retry
  # without changing the user-visible work.
  defp stale_worker_transition(repo, %AgentComputerWorker{} = worker, now, reason) do
    with {:ok, worker} <- mark_worker_stale(repo, worker, now, reason),
         {_delivery_count, _rows} <-
           supersede_unaccepted_deliveries_for_worker(repo, worker, now, reason),
         {_assignment_count, _rows} <- WorkerPool.release_assignments_for_worker(repo, worker) do
      {:ok, worker}
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

  # Supersedes only created/sent deliveries. Accepted deliveries are already in
  # the commit path and must be resolved by turn fencing rather than worker
  # staleness alone.
  defp supersede_unaccepted_deliveries_for_worker(
         repo,
         %AgentComputerWorker{} = worker,
         now,
         reason
       ) do
    ActorInputDelivery
    |> where([delivery], delivery.worker_id == ^worker.worker_id)
    |> where([delivery], delivery.worker_instance_id == ^worker.worker_instance_id)
    |> where([delivery], delivery.state in ["created", "sent"])
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end

  # Normalizes the transport boundary into a plain route string. Tests may pass
  # the route directly; production passes a small authenticated route map.
  defp authenticated_route(route) when is_binary(route) and route != "",
    do: {:ok, %{route: route, worker_id: nil, key_revision: nil}}

  defp authenticated_route(
         %{authenticated?: true, transport_route: route, worker_id: worker_id} = auth
       )
       when is_binary(route) and route != "" and is_binary(worker_id) and worker_id != "",
       do:
         {:ok, %{route: route, worker_id: worker_id, key_revision: Map.get(auth, :key_revision)}}

  defp authenticated_route(%{authenticated?: true, transport_route: route})
       when is_binary(route) and route != "",
       do: {:ok, %{route: route, worker_id: nil, key_revision: nil}}

  defp authenticated_route(
         %{"authenticated" => true, "transport_route" => route, "worker_id" => worker_id} = auth
       )
       when is_binary(route) and route != "" and is_binary(worker_id) and worker_id != "",
       do:
         {:ok, %{route: route, worker_id: worker_id, key_revision: Map.get(auth, "key_revision")}}

  defp authenticated_route(%{"authenticated" => true, "transport_route" => route})
       when is_binary(route) and route != "",
       do: {:ok, %{route: route, worker_id: nil, key_revision: nil}}

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

  # Extracts only the data needed to place homogeneous workers. Runtime and
  # version stay as observability metadata instead of becoming scheduling axes.
  defp worker_ready_attrs(worker_ready, route) do
    with {:ok, worker_id} <- fetch_required_text(worker_ready, "worker_id"),
         {:ok, worker_instance_id} <- fetch_required_text(worker_ready, "worker_instance_id"),
         {:ok, runtime} <- fetch_required_text(worker_ready, "runtime"),
         {:ok, version} <- fetch_required_text(worker_ready, "version") do
      {:ok,
       %{
         worker_id: worker_id,
         worker_instance_id: worker_instance_id,
         status: @ready_worker_status,
         version: version,
         capacity:
           fetch_map(worker_ready, "capacity_json") || fetch_map(worker_ready, "capacity") || %{},
         load: fetch_map(worker_ready, "load") || %{},
         transport_route: route,
         metadata: %{"runtime" => runtime}
       }}
    end
  end

  defp fetch_required_text(map, key) do
    case fetch_text(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  defp fetch_text(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_map(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_int(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
