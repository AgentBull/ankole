defmodule Ankole.SignalsGateway.ActorRuntime.WorkerPool do
  @moduledoc """
  Worker placement boundary for actor sessions.

  Maps an actor key to a ready worker. Placement is per Session: one Session or
  Job stays on its assigned worker while that worker is usable, because the
  Codex thread state of a Job lives in that worker's local runtime shard. Jobs
  and Sessions of one Agent may run on several workers at once; single-Job
  exclusivity is owned by the Session-scoped delivery, activation, and turn
  fences, not by an Agent-level pin. Assignments remain rebuildable hints:
  the `agent_computer_worker` table remains the liveness source, and every
  placement revalidates the worker behind the assignment. If the assigned worker
  is gone, the assignment is released and re-placed.

  An assignment is not part of the durable user story: no committed work is lost
  when one goes away. What a move does cost is the worker-local Codex thread. A
  Job that moves rebuilds its thread and loses the context it had accumulated,
  and a Job that inherited a thread from another Job cannot resume it at all, so
  a continuation carries its source's assignment forward through
  `inherit_assignment_in_tx/4` instead of being placed by capacity alone. Only a
  caller that has no thread to keep should release an assignment.

  Placement deliberately considers only liveness and free capacity because all
  workers run one image; a heterogeneous pool is out of scope for this path.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL

  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobWorkerConfig
  alias Ankole.SignalsGateway.ActorRuntime.Common
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
    actor_key = Common.normalize_actor_key(actor_key)
    now = DateTime.utc_now(:microsecond)

    job_limit = job_turn_limit(actor_key)

    Repo.transact(fn repo -> assign_worker_in_tx(repo, actor_key, now, job_limit) end)
  end

  @doc """
  Resolves how many BackgroundAgentJob turns one worker may hold, or `nil` for a
  session that does not consume Job placement capacity.

  Callers resolve this before they open the placement transaction. AppConfigure
  reads reach a separate process and a separate connection, which a transaction
  must not wait on.
  """
  @spec job_turn_limit(actor_key() | map()) :: pos_integer() | nil
  def job_turn_limit(actor_key), do: actor_key |> Common.normalize_actor_key() |> job_limit()

  @doc false
  @spec assign_worker_in_tx(module(), actor_key() | map(), DateTime.t(), pos_integer() | nil) ::
          {:ok, ActorSessionWorkerAssignment.t()} | {:error, term()}
  def assign_worker_in_tx(repo, actor_key, %DateTime{} = now, job_limit) do
    actor_key = Common.normalize_actor_key(actor_key)

    with :ok <- lock_actor_assignment_in_tx(repo, actor_key) do
      do_assign_worker_in_tx(repo, actor_key, now, job_limit)
    end
  end

  @doc """
  Returns a live worker route for filesystem operations.

  Worker-file operations are not actor turns and do not consume turn capacity.
  They only need one ready worker that can reach the shared filesystem.
  """
  @spec file_worker_route() :: {:ok, String.t()} | {:error, :no_worker_available}
  def file_worker_route do
    file_worker_route_in_tx(Repo)
  end

  defp file_worker_route_in_tx(repo) do
    AgentComputerWorker
    |> where([worker], worker.status == ^@ready_worker_status)
    |> order_by([worker], asc: worker.inserted_at)
    |> repo.all()
    |> Enum.find_value(&worker_route/1)
    |> case do
      route when is_binary(route) and route != "" -> {:ok, route}
      _missing -> {:error, :no_worker_available}
    end
  end

  @doc """
  Lists the live route of every ready worker.

  Worker-local runtime shard maintenance must reach every worker, because the
  control plane does not track which workers hold a shard for an Agent; a
  worker without one treats the operation as a no-op.
  """
  @spec ready_worker_routes() :: [String.t()]
  def ready_worker_routes do
    AgentComputerWorker
    |> where([worker], worker.status == ^@ready_worker_status)
    |> order_by([worker], asc: worker.inserted_at)
    |> Repo.all()
    |> Enum.map(&worker_route/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  @doc """
  Resolves the live route for one specific worker.

  Workers mount the installation's shared RWX Agent filesystem, but this operator API
  deliberately targets one worker so mount reachability and failures remain
  attributable to the selected runtime. Unlike `file_worker_route/0`, it never
  falls back to another worker.
  """
  @spec worker_file_route(String.t()) ::
          {:ok, String.t()} | {:error, :worker_not_found | :worker_not_ready}
  def worker_file_route(worker_id) when is_binary(worker_id) do
    worker_file_route_in_tx(Repo, worker_id)
  end

  defp worker_file_route_in_tx(repo, worker_id) do
    case repo.get_by(AgentComputerWorker, worker_id: worker_id) do
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

  @doc """
  Copies one actor's live assignment onto another actor key.

  A steer successor Job continues its source Job's Codex thread, and that thread
  lives in one worker's local runtime shard. The successor is a new Session, so
  ordinary placement would pick by free capacity and prefer a worker without the
  thread. Copying the assignment makes placement reuse the same worker through
  the normal revalidation path, which still moves the Job when that worker is
  gone. It reserves no turn capacity: the successor claims its slot when it
  starts.

  A source without a live assignment returns `:ok`. There is then no thread host
  to inherit and ordinary placement is already correct.
  """
  @spec inherit_assignment_in_tx(module(), actor_key() | map(), actor_key() | map(), DateTime.t()) ::
          :ok | {:error, term()}
  def inherit_assignment_in_tx(repo, source_actor_key, target_actor_key, %DateTime{} = now) do
    source_actor_key = Common.normalize_actor_key(source_actor_key)
    target_actor_key = Common.normalize_actor_key(target_actor_key)

    case live_assignment_snapshot(repo, source_actor_key) do
      %ActorSessionWorkerAssignment{} = assignment ->
        case insert_assignment(repo, target_actor_key, assignment, now) do
          {:ok, _assignment} -> :ok
          {:error, _reason} = error -> error
        end

      nil ->
        :ok
    end
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

  # The advisory lock is per actor key, so it serializes placement of one Session
  # or Job without blocking the Agent's others. Reading the assignment first
  # without a row lock lets revalidation acquire the worker before the
  # assignment, matching worker-stale recovery's global lock order.
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
  # slots in its ready/capacity envelopes. The worker with the most free turn
  # slots wins, so concurrent Jobs of one Agent spread across the pool instead
  # of stacking on the oldest worker.
  defp choose_worker(repo, job_limit) do
    AgentComputerWorker
    |> where([worker], worker.status == ^@ready_worker_status)
    |> order_by([worker], asc: worker.inserted_at)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> repo.all()
    |> Enum.sort_by(&available_turn_slots/1, :desc)
    |> Enum.find(fn worker ->
      worker_has_capacity?(worker) and
        worker_has_job_capacity?(repo, worker, job_limit)
    end)
  end

  defp available_turn_slots(%AgentComputerWorker{capacity: %{"available_turn_slots" => slots}})
       when is_integer(slots),
       do: slots

  defp available_turn_slots(%AgentComputerWorker{}), do: 0

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
    case Map.get(capacity, "available_turn_slots") do
      slots when is_integer(slots) ->
        Map.put(capacity, "available_turn_slots", max(slots - 1, 0))

      _value ->
        capacity
    end
  end

  defp reserve_load(load) when is_map(load) do
    active_turns =
      case Map.get(load, "active_turns") do
        value when is_integer(value) -> value
        _value -> 0
      end

    Map.put(load, "active_turns", active_turns + 1)
  end

  defp reserve_load(_load), do: %{"active_turns" => 1}

  defp worker_has_capacity?(%AgentComputerWorker{
         capacity: %{"available_turn_slots" => slots}
       })
       when is_integer(slots),
       do: slots > 0

  defp worker_has_capacity?(%AgentComputerWorker{}), do: false

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
  # A worker row and an existing assignment carry the same route pair, so both
  # can seed a new assignment.
  defp insert_assignment(repo, actor_key, %{worker_id: worker_id} = route, now) do
    %ActorSessionWorkerAssignment{}
    |> ActorSessionWorkerAssignment.changeset(%{
      agent_uid: actor_key.agent_uid,
      session_id: actor_key.session_id,
      worker_id: worker_id,
      transport_route: route.transport_route,
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

  @doc false
  @spec lock_actor_assignment_in_tx(module(), actor_key() | map()) :: :ok | {:error, term()}
  def lock_actor_assignment_in_tx(repo, actor_key) do
    actor_key = Common.normalize_actor_key(actor_key)

    case SQL.query(
           repo,
           "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
           ["#{actor_key.agent_uid}/#{actor_key.session_id}", "actor-worker"]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp job_limit(%{session_id: session_id})
       when BackgroundAgentJobs.is_job_session_id(session_id),
       do: BackgroundAgentJobWorkerConfig.max_turns_per_worker()

  defp job_limit(_actor_key), do: nil
end
