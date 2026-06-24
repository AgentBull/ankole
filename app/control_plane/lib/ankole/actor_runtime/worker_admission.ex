defmodule Ankole.ActorRuntime.WorkerAdmission do
  @moduledoc """
  Worker admission boundary for authenticated Actor Bus lifecycle messages.
  """

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.Repo

  @ready_worker_status "ready"
  @stale_worker_statuses ~w(ready draining)

  @doc """
  Admits an authenticated worker-ready message.
  """
  @spec admit_worker_ready(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def admit_worker_ready(worker_ready, authenticated_route) when is_map(worker_ready) do
    with {:ok, route} <- authenticated_route(authenticated_route),
         {:ok, attrs} <- worker_ready_attrs(worker_ready, route) do
      record_worker_ready(attrs, route)
    end
  end

  @doc """
  Records a worker-ready projection.
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
  """
  @spec handle_worker_heartbeat(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def handle_worker_heartbeat(worker_heartbeat, authenticated_route)
      when is_map(worker_heartbeat) do
    with {:ok, route} <- authenticated_route(authenticated_route),
         {:ok, worker_id} <- fetch_required_text(worker_heartbeat, "worker_id"),
         {:ok, worker_instance_id} <- fetch_required_text(worker_heartbeat, "worker_instance_id") do
      update_worker_projection(worker_id, worker_instance_id, route, %{
        last_worker_heartbeat_at: DateTime.utc_now(:microsecond),
        load: fetch_map(worker_heartbeat, "load_json") || %{}
      })
    end
  end

  @doc """
  Records an authenticated worker capacity projection.
  """
  @spec handle_worker_capacity(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  def handle_worker_capacity(worker_capacity, authenticated_route) when is_map(worker_capacity) do
    with {:ok, route} <- authenticated_route(authenticated_route),
         {:ok, worker_id} <- fetch_required_text(worker_capacity, "worker_id"),
         {:ok, worker_instance_id} <- fetch_required_text(worker_capacity, "worker_instance_id") do
      capacity =
        worker_capacity
        |> fetch_map("capacity_json")
        |> case do
          %{} = capacity ->
            capacity

          _value ->
            %{"available_turn_slots" => fetch_int(worker_capacity, "available_turn_slots") || 0}
        end

      update_worker_projection(worker_id, worker_instance_id, route, %{
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

  defp authenticated_route(route) when is_binary(route) and route != "", do: {:ok, route}

  defp authenticated_route(%{authenticated?: true, transport_route: route})
       when is_binary(route) and route != "",
       do: {:ok, route}

  defp authenticated_route(%{"authenticated" => true, "transport_route" => route})
       when is_binary(route) and route != "",
       do: {:ok, route}

  defp authenticated_route(_route), do: {:error, :unauthenticated_worker_route}

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
