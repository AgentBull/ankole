defmodule Ankole.SignalsGateway.ActorRuntime.WorkerPool do
  @moduledoc """
  Worker placement boundary for actor sessions.

  Maps an actor key to a ready worker. Every live Session or Job for one Agent
  stays on one worker so Agent-level Codex state is never actively used by two
  worker instances. Assignments remain rebuildable hints:
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
  alias Ankole.Logging
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
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
      case live_agent_worker_ids(repo, actor_key.agent_uid) do
        [] ->
          do_assign_worker_in_tx(repo, actor_key, now, job_limit(actor_key))

        [worker_id] ->
          assign_pinned_worker(repo, actor_key, worker_id, now, job_limit(actor_key))

        worker_ids ->
          Logging.warning(
            "signals_gateway.worker_pool.agent_worker_overlap",
            "Agent has live deliveries on multiple workers; placement is held until fences converge",
            %{agent_uid: actor_key.agent_uid, worker_ids: worker_ids}
          )

          {:error, :no_worker_available}
      end
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
  Runs a short Agent Home operation against its single ready Worker.

  The Agent placement advisory lock stays held through the callback, so a new
  turn cannot move the Agent to another Worker between route selection and the
  operation. The callback must return a tagged result for `Repo.transact/1`.
  """
  @spec with_agent_file_worker_route(
          String.t(),
          (String.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def with_agent_file_worker_route(agent_uid, operation)
      when is_binary(agent_uid) and is_function(operation, 1) do
    agent_uid = normalize_uid(agent_uid)

    Repo.transact(fn repo ->
      with :ok <- lock_agent_worker_in_tx(repo, agent_uid),
           {:ok, route} <- agent_file_worker_route_in_tx(repo, agent_uid) do
        operation.(route)
      end
    end)
  end

  defp agent_file_worker_route_in_tx(repo, agent_uid) do
    worker_ids =
      repo
      |> live_agent_worker_ids(agent_uid)
      |> Kernel.++(assigned_agent_worker_ids(repo, agent_uid))
      |> Enum.uniq()
      |> Enum.sort()

    case worker_ids do
      [] -> file_worker_route_in_tx(repo)
      [worker_id] -> worker_file_route_in_tx(repo, worker_id)
      _worker_ids -> {:error, :agent_worker_overlap}
    end
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

  # The Agent advisory lock serializes placement across all of its Sessions and Jobs. Reading the
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

  defp assign_pinned_worker(repo, actor_key, worker_id, now, job_limit) do
    worker = lock_assignment_worker(repo, worker_id)
    assignment = live_assignment_snapshot(repo, actor_key)
    assignment = if assignment, do: lock_live_assignment(repo, assignment, actor_key)

    cond do
      not match?(%AgentComputerWorker{status: @ready_worker_status}, worker) ->
        {:error, :no_worker_available}

      not worker_has_capacity?(worker) or not worker_has_job_capacity?(repo, worker, job_limit) ->
        {:error, :no_worker_available}

      match?(%ActorSessionWorkerAssignment{worker_id: ^worker_id}, assignment) ->
        with {:ok, worker} <- reserve_worker_slot(repo, worker) do
          touch_assignment(repo, assignment, worker, now)
        end

      match?(%ActorSessionWorkerAssignment{}, assignment) ->
        with {:ok, _released} <- release_assignment(repo, assignment),
             {:ok, worker} <- reserve_worker_slot(repo, worker) do
          insert_assignment(repo, actor_key, worker, now)
        end

      true ->
        with {:ok, worker} <- reserve_worker_slot(repo, worker) do
          insert_assignment(repo, actor_key, worker, now)
        end
    end
  end

  defp live_agent_worker_ids(repo, agent_uid) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^agent_uid)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> where([delivery], not is_nil(delivery.worker_id))
    |> select([delivery], delivery.worker_id)
    |> distinct(true)
    |> repo.all()
    |> Enum.sort()
  end

  defp assigned_agent_worker_ids(repo, agent_uid) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^agent_uid)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> select([assignment], assignment.worker_id)
    |> distinct(true)
    |> repo.all()
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
    lock_agent_worker_in_tx(repo, actor_key.agent_uid)
  end

  defp lock_agent_worker_in_tx(repo, agent_uid) do
    case SQL.query(
           repo,
           "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
           [agent_uid, "agent-worker"]
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
