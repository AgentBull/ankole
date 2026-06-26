defmodule Ankole.ActorRuntime.WorkerPool do
  @moduledoc """
  Worker placement boundary for actor sessions.

  Maps an actor key to a ready worker. Assignments are sticky (an actor reuses
  the same worker while it stays usable, to cut churn) but they are only hints:
  the `agent_computer_worker` table remains the liveness source, and every
  placement revalidates the worker behind the assignment. If the assigned worker
  is gone, the assignment is released and re-placed. Crucially, an assignment is
  not part of the durable user story — losing one only means the actor input is
  retried onto another worker, never that work is dropped. Placement deliberately
  considers only liveness and free capacity because all workers run one image; a
  heterogeneous pool is out of scope for this path.
  """

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo

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
  Releases live assignments for a worker that is no longer usable.

  Called inside the worker-staleness transition (see `WorkerAdmission`) so that
  marking a worker stale and detaching its actor sessions commit together. Fences
  on `worker_instance_id` as well as `worker_id`, so a worker that has since
  reconnected under a new instance keeps its current assignments. Returns the
  Ecto `update_all` count tuple.
  """
  @spec release_assignments_for_worker(module(), AgentComputerWorker.t()) ::
          {non_neg_integer(), nil | [term()]}
  def release_assignments_for_worker(repo, %AgentComputerWorker{} = worker) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.worker_id == ^worker.worker_id)
    |> where([assignment], assignment.worker_instance_id == ^worker.worker_instance_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.update_all(set: [status: "released", updated_at: DateTime.utc_now(:microsecond)])
  end

  # Keeps actor-to-worker affinity while the assigned worker is still usable.
  # This lowers churn without making the worker part of the durable user story:
  # stale workers release the assignment and the actor input can be retried.
  defp assign_worker_in_tx(repo, actor_key, now) do
    case live_assignment(repo, actor_key) do
      %ActorSessionWorkerAssignment{} = assignment ->
        case assignment_worker_available(repo, assignment) do
          %AgentComputerWorker{} ->
            touch_assignment(repo, assignment, now)

          nil ->
            with {:ok, _assignment} <- release_assignment(repo, assignment),
                 {:ok, assignment} <- assign_new_worker(repo, actor_key, now) do
              {:ok, assignment}
            end
        end

      nil ->
        assign_new_worker(repo, actor_key, now)
    end
  end

  # Locks one live assignment for the actor key so concurrent wakeups do not
  # create multiple worker routes for the same ready input prefix.
  defp live_assignment(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Picks the first currently ready worker with capacity. The policy is simple
  # on purpose: fairness can improve later without changing turn semantics.
  defp assign_new_worker(repo, actor_key, now) do
    with %AgentComputerWorker{} = worker <- choose_worker(repo),
         {:ok, assignment} <- insert_assignment(repo, actor_key, worker, now) do
      {:ok, assignment}
    else
      nil -> {:error, :no_worker_available}
      {:error, _reason} = error -> error
    end
  end

  # Revalidates the worker projection behind an existing assignment. Assignment
  # rows are hints; the worker table remains the liveness source.
  defp assignment_worker_available(repo, assignment) do
    AgentComputerWorker
    |> where([worker], worker.worker_id == ^assignment.worker_id)
    |> where([worker], worker.worker_instance_id == ^assignment.worker_instance_id)
    |> where([worker], worker.status == ^@ready_worker_status)
    |> repo.one()
    |> case do
      %AgentComputerWorker{} = worker ->
        case worker_has_capacity?(worker) do
          true -> worker
          false -> nil
        end

      nil ->
        nil
    end
  end

  defp release_assignment(repo, %ActorSessionWorkerAssignment{} = assignment) do
    assignment
    |> ActorSessionWorkerAssignment.changeset(%{status: "released"})
    |> repo.update()
  end

  defp touch_assignment(repo, assignment, now) do
    assignment
    |> ActorSessionWorkerAssignment.changeset(%{last_used_at: now})
    |> repo.update()
  end

  # Chooses from ready workers after reading their current capacity projection.
  # Missing capacity means "usable" so early workers can participate before they
  # implement richer load reporting.
  defp choose_worker(repo) do
    AgentComputerWorker
    |> where([worker], worker.status == ^@ready_worker_status)
    |> order_by([worker], asc: worker.inserted_at)
    |> repo.all()
    |> Enum.find(&worker_has_capacity?/1)
  end

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
      nil -> true
    end
  end

  # Captures the route chosen for this actor session. Later delivery still
  # fences on worker instance id so a reconnected worker cannot inherit old work
  # just because it has the same logical worker id.
  defp insert_assignment(repo, actor_key, worker, now) do
    %ActorSessionWorkerAssignment{}
    |> ActorSessionWorkerAssignment.changeset(%{
      agent_uid: actor_key.agent_uid,
      session_id: actor_key.session_id,
      worker_id: worker.worker_id,
      worker_instance_id: worker.worker_instance_id,
      transport_route: worker.transport_route,
      status: "assigned",
      assigned_at: now,
      last_used_at: now,
      metadata: %{}
    })
    |> repo.insert()
  end

  defp worker_route(%AgentComputerWorker{} = worker) do
    worker.transport_route || worker.worker_instance_id || worker.worker_id
  end

  defp normalize_actor_key(%{agent_uid: agent_uid, session_id: session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_actor_key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)

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
