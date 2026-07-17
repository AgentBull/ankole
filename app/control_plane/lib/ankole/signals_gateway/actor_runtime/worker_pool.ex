defmodule Ankole.SignalsGateway.ActorRuntime.WorkerPool do
  @moduledoc """
  Worker placement boundary for actor sessions.

  Maps an actor key to a ready worker. Assignments are sticky (an actor reuses
  the same worker while it stays usable, to cut churn) but they are only hints:
  the `agent_computer_worker` table remains the liveness source, and every
  placement revalidates the worker behind the assignment. If the assigned worker
  is gone, the assignment is released and re-placed. Crucially, an assignment is
  not part of the durable user story — losing one only means the actor event is
  retried onto another worker, never that work is dropped. Placement deliberately
  considers only liveness and free capacity because all workers run one image; a
  heterogeneous pool is out of scope for this path.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL

  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobWorkerConfig
  alias Ankole.Repo

  require Ankole.BackgroundAgentJobs

  @ready_worker_status "ready"

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Assigns one homogeneous ready worker to an actor session.

  Placement only needs liveness and capacity because all workers run the same
  image. A future heterogeneous pool is not a requirement of this runtime path.
  """
  @spec assign_worker(actor_key() | map()) ::
          {:ok, ActorSessionWorkerAssignment.t()} | {:error, term()}
  def assign_worker(actor_key) do
    actor_key = normalize_actor_key(actor_key)
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo -> assign_worker_in_tx(repo, actor_key, now) end)
  end

  @doc false
  @spec assign_worker_in_tx(module(), actor_key() | map(), DateTime.t()) ::
          {:ok, ActorSessionWorkerAssignment.t()} | {:error, term()}
  def assign_worker_in_tx(repo, actor_key, %DateTime{} = now) do
    actor_key = normalize_actor_key(actor_key)

    with :ok <- lock_actor_assignment_in_tx(repo, actor_key) do
      do_assign_worker_in_tx(repo, actor_key, now, job_limit(actor_key))
    end
  end

  @doc """
  Returns a live worker route for filesystem operations.

  Worker-file operations are not actor turns and do not consume turn capacity.
  They only need one ready worker that can reach the shared filesystem.
  """
  @spec file_worker_route() :: {:ok, String.t()} | {:error, :no_worker_available}
  def file_worker_route do
    AgentComputerWorker
    |> where([worker], worker.status == ^@ready_worker_status)
    |> order_by([worker], asc: worker.inserted_at)
    |> Repo.all()
    |> Enum.find_value(&worker_route/1)
    |> case do
      route when is_binary(route) and route != "" -> {:ok, route}
      _missing -> {:error, :no_worker_available}
    end
  end

  @doc """
  Resolves the live route for one specific worker.

  Workers mount the installation's shared RWX workspace, but this operator API
  deliberately targets one worker so mount reachability and failures remain
  attributable to the selected runtime. Unlike `file_worker_route/0`, it never
  falls back to another worker.
  """
  @spec worker_file_route(String.t()) ::
          {:ok, String.t()} | {:error, :worker_not_found | :worker_not_ready}
  def worker_file_route(worker_id) when is_binary(worker_id) do
    case Repo.get_by(AgentComputerWorker, worker_id: worker_id) do
      nil ->
        {:error, :worker_not_found}

      %AgentComputerWorker{status: @ready_worker_status} = worker ->
        case worker_route(worker) do
          route when is_binary(route) and route != "" -> {:ok, route}
          _missing -> {:error, :worker_not_ready}
        end

      %AgentComputerWorker{} ->
        {:error, :worker_not_ready}
    end
  end

  @doc """
  Releases live assignments for a worker that is no longer usable.

  Called inside the worker-staleness transition (see `WorkerAdmission`) so that
  marking a worker stale and detaching its actor sessions commit together.
  Returns the Ecto `update_all` count tuple.
  """
  @spec release_assignments_for_worker(module(), AgentComputerWorker.t()) ::
          {non_neg_integer(), nil | [term()]}
  def release_assignments_for_worker(repo, %AgentComputerWorker{} = worker) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.worker_id == ^worker.worker_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.update_all(set: [status: "released", updated_at: DateTime.utc_now(:microsecond)])
  end

  @doc false
  def release_assignment_for_actor_in_tx(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.update_all(set: [status: "released", updated_at: DateTime.utc_now(:microsecond)])

    :ok
  end

  # Keeps actor-to-worker affinity while the assigned worker is still usable.
  # This lowers churn without making the worker part of the durable user story:
  # stale workers release the assignment and the actor event can be retried.
  defp do_assign_worker_in_tx(repo, actor_key, now, job_limit) do
    case live_assignment_snapshot(repo, actor_key) do
      %ActorSessionWorkerAssignment{} = assignment ->
        reuse_or_replace_assignment(repo, actor_key, assignment, now, job_limit)

      nil ->
        assign_new_worker(repo, actor_key, now, job_limit)
    end
  end

  # The actor advisory lock serializes placement for one session. Reading the
  # assignment first without a row lock lets revalidation acquire the worker
  # before the assignment, matching worker-stale recovery's global lock order.
  defp live_assignment_snapshot(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.one()
  end

  # Picks the first currently ready worker with capacity. The policy is simple
  # on purpose: fairness can improve later without changing turn semantics.
  defp assign_new_worker(repo, actor_key, now, job_limit) do
    with %AgentComputerWorker{} = worker <- choose_worker(repo, job_limit),
         {:ok, worker} <- reserve_worker_slot(repo, worker),
         {:ok, assignment} <- insert_assignment(repo, actor_key, worker, now) do
      {:ok, assignment}
    else
      nil -> {:error, :no_worker_available}
      {:error, _reason} = error -> error
    end
  end

  defp reuse_or_replace_assignment(repo, actor_key, assignment, now, job_limit) do
    worker = lock_assignment_worker(repo, assignment.worker_id)
    assignment = lock_live_assignment(repo, assignment, actor_key)

    cond do
      match?(%AgentComputerWorker{status: @ready_worker_status}, worker) and
        match?(%ActorSessionWorkerAssignment{}, assignment) and
        worker_has_capacity?(worker) and
          worker_has_job_capacity?(repo, worker, job_limit) ->
        with {:ok, worker} <- reserve_worker_slot(repo, worker) do
          touch_assignment(repo, assignment, worker, now)
        end

      match?(%ActorSessionWorkerAssignment{}, assignment) ->
        with {:ok, _assignment} <- release_assignment(repo, assignment),
             {:ok, assignment} <- assign_new_worker(repo, actor_key, now, job_limit) do
          {:ok, assignment}
        end

      true ->
        assign_new_worker(repo, actor_key, now, job_limit)
    end
  end

  defp lock_assignment_worker(repo, worker_id) do
    AgentComputerWorker
    |> where([worker], worker.worker_id == ^worker_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_live_assignment(repo, assignment, actor_key) do
    ActorSessionWorkerAssignment
    |> where([stored], stored.id == ^assignment.id)
    |> where([stored], stored.agent_uid == ^actor_key.agent_uid)
    |> where([stored], stored.session_id == ^actor_key.session_id)
    |> where([stored], stored.worker_id == ^assignment.worker_id)
    |> where([stored], stored.status in ["assigned", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp release_assignment(repo, %ActorSessionWorkerAssignment{} = assignment) do
    assignment
    |> ActorSessionWorkerAssignment.changeset(%{status: "released"})
    |> repo.update()
  end

  defp touch_assignment(repo, assignment, worker, now) do
    assignment
    |> ActorSessionWorkerAssignment.changeset(%{
      last_used_at: now,
      transport_route: worker.transport_route
    })
    |> repo.update()
  end

  # Chooses from ready workers after reading their current capacity projection.
  # Missing capacity is not assumed usable: every current worker reports turn
  # slots in its ready/capacity envelopes.
  defp choose_worker(repo, job_limit) do
    AgentComputerWorker
    |> where([worker], worker.status == ^@ready_worker_status)
    |> order_by([worker], asc: worker.inserted_at)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> repo.all()
    |> Enum.find(fn worker ->
      worker_has_capacity?(worker) and
        worker_has_job_capacity?(repo, worker, job_limit)
    end)
  end

  defp reserve_worker_slot(repo, %AgentComputerWorker{} = worker) do
    case worker_has_capacity?(worker) do
      true ->
        worker
        |> AgentComputerWorker.changeset(%{
          capacity: reserve_capacity(worker.capacity),
          load: reserve_load(worker.load)
        })
        |> repo.update()

      false ->
        {:error, :no_worker_available}
    end
  end

  defp reserve_capacity(capacity) when is_map(capacity) do
    case integer_from_map(capacity, "available_turn_slots") do
      slots when is_integer(slots) ->
        Map.put(capacity, "available_turn_slots", max(slots - 1, 0))

      nil ->
        capacity
    end
  end

  defp reserve_capacity(_capacity), do: %{}

  defp reserve_load(load) when is_map(load) do
    active_turns = integer_from_map(load, "active_turns") || 0
    Map.put(load, "active_turns", active_turns + 1)
  end

  defp reserve_load(_load), do: %{"active_turns" => 1}

  # Accepts either explicit available slots or max-minus-active reporting. This
  # keeps the worker protocol small while allowing older and newer workers to
  # share the same homogeneous pool.
  defp worker_has_capacity?(%AgentComputerWorker{capacity: capacity, load: load}) do
    available_slots =
      integer_from_map(capacity, "available_turn_slots") ||
        case {integer_from_map(capacity, "max_turns"), integer_from_map(load, "active_turns")} do
          {max_turns, active_turns} when is_integer(max_turns) and is_integer(active_turns) ->
            max_turns - active_turns

          _value ->
            nil
        end

    case available_slots do
      slots when is_integer(slots) -> slots > 0
      nil -> false
    end
  end

  defp worker_has_job_capacity?(_repo, _worker, nil), do: true

  defp worker_has_job_capacity?(repo, worker, limit) when is_integer(limit) do
    count =
      repo.aggregate(
        from(assignment in ActorSessionWorkerAssignment,
          where: assignment.worker_id == ^worker.worker_id,
          where: assignment.status in ["assigned", "draining"],
          where: like(assignment.session_id, ^(BackgroundAgentJobs.job_session_prefix() <> "%"))
        ),
        :count
      )

    count < limit
  end

  # Captures the route chosen for this actor session. Delivery and turn replies
  # re-check the route so assignment remains a placement hint, not durable truth.
  defp insert_assignment(repo, actor_key, worker, now) do
    %ActorSessionWorkerAssignment{}
    |> ActorSessionWorkerAssignment.changeset(%{
      agent_uid: actor_key.agent_uid,
      session_id: actor_key.session_id,
      worker_id: worker.worker_id,
      transport_route: worker.transport_route,
      status: "assigned",
      assigned_at: now,
      last_used_at: now,
      metadata: %{}
    })
    |> repo.insert()
  end

  defp worker_route(%AgentComputerWorker{} = worker) do
    worker.transport_route || worker.worker_id
  end

  defp normalize_actor_key(%{agent_uid: agent_uid, session_id: session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_actor_key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)

  @doc false
  @spec lock_actor_assignment_in_tx(module(), actor_key() | map()) :: :ok | {:error, term()}
  def lock_actor_assignment_in_tx(repo, actor_key) do
    actor_key = normalize_actor_key(actor_key)

    case SQL.query(
           repo,
           "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
           [actor_key.agent_uid, actor_key.session_id]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp job_limit(%{session_id: session_id})
       when BackgroundAgentJobs.is_job_session_id(session_id),
       do: BackgroundAgentJobWorkerConfig.max_turns_per_worker()

  defp job_limit(_actor_key), do: nil

  defp integer_from_map(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> nil
    end
  end

  defp integer_from_map(_map, _key), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> nil
    end
  end
end
