defmodule Ankole.AgentWorkers.WorkerRouteAuth do
  @moduledoc "Accepts Worker RPC only for its bound Agent and current durable input or Job attempt."
  alias Ankole.{Principals.WorkAccess, Repo}
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.RunRef
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.RunnerConnection

  @doc """
  Authorizes one Worker RPC in its own transaction.

  The transaction takes the same locks as a terminal write, so the check
  waits for a concurrent cancellation or terminal write to commit.
  """
  def authorize_turn(ref, worker, effect) do
    case Repo.transact_top_level(fn -> authorize_turn_in_tx(ref, worker, effect) end) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def authorize_turn_in_tx(ref, worker_id, effect, opts \\ [])

  def authorize_turn_in_tx(%JobTurnRef{} = ref, worker, effect, opts)
      when effect in [:read, :write, :terminal] do
    # The locked Job and attempt fence serialize cancellation and terminal
    # writes. Lock the input only when its lifecycle mutation runs, after
    # Turn and Session locks.
    with {:ok, source} <- source(ref, worker),
         :ok <- check_worker(ref, source, effect),
         %Job{attempts: attempt, status: status} = job <- job(ref, effect),
         :ok <- assigned(job, source),
         true <- attempt == ref.attempt and (status == :running or effect == :terminal),
         :ok <- input(ref, status != :running, Keyword.delete(opts, :lock)) do
      {:ok, :authorized}
    else
      {:error, _} = error -> error
      _ -> {:error, :background_agent_job_attempt_changed}
    end
  end

  def authorize_turn_in_tx(%RunRef{} = ref, worker, effect, opts)
      when effect in [:read, :write, :terminal] do
    with {:ok, :managed} <- source(ref, worker),
         :ok <- input(ref, false, opts) do
      {:ok, :authorized}
    else
      {:ok, _} -> {:error, :worker_not_assigned_to_turn}
      error -> error
    end
  end

  def authorize_turn_in_tx(_ref, _worker_id, _effect, _opts),
    do: {:error, :worker_not_assigned_to_turn}

  defp source(%JobTurnRef{}, :internal), do: {:ok, :internal}

  defp source(%{agent_uid: uid}, %{worker_id: uid, runner_id: runner_id} = worker)
       when is_binary(runner_id),
       do: {:ok, worker}

  defp source(%JobTurnRef{agent_uid: uid, worker: %{worker_id: uid} = worker}, uid),
    do: {:ok, worker}

  defp source(%{agent_uid: uid}, %{worker_id: uid, runner_id: nil}), do: {:ok, :managed}

  defp source(%{agent_uid: uid}, %{worker_id: uid} = worker)
       when not is_map_key(worker, :runner_id),
       do: {:ok, :managed}

  defp source(%{agent_uid: uid}, uid), do: {:ok, :managed}
  defp source(_ref, _worker), do: {:error, :worker_not_assigned_to_turn}

  defp check_worker(_ref, worker, :read) when is_map(worker) do
    if RunnerConnection.current?(worker), do: :ok, else: {:error, :stale_transport_route}
  end

  defp check_worker(_ref, _worker, :read), do: :ok

  defp check_worker(%{agent_uid: uid}, :managed, _effect) do
    AgentWorkers.lock_in_tx(uid)
    Lifecycle.lock_agent_slots(uid)
  end

  defp check_worker(ref, :internal, _effect) do
    case job(ref, :read) do
      %Job{} = job ->
        BackgroundAgentJobs.lock_worker_in_tx(job)
        Lifecycle.lock_agent_slots(ref.agent_uid)

      nil ->
        {:error, :job_not_found}
    end
  end

  defp check_worker(ref, worker, _effect) do
    with :ok <- RunnerConnection.lock_current_in_tx(worker),
         do: Lifecycle.lock_agent_slots(ref.agent_uid)
  end

  defp assigned(%Job{runner_id: runner_id}, %{runner_id: runner_id}), do: :ok
  defp assigned(%Job{runner_id: nil}, :managed), do: :ok
  defp assigned(_job, :internal), do: :ok
  defp assigned(_job, _worker), do: {:error, :worker_not_assigned_to_turn}

  defp job(ref, :read),
    do: BackgroundAgentJobs.get_job_for_agent(ref.job_id, ref.agent_uid)

  defp job(ref, _effect),
    do: BackgroundAgentJobs.lock_job_in_tx(ref.job_id, ref.agent_uid)

  defp admitted_access(%{last_attempt_at: %DateTime{}}), do: :ok
  defp admitted_access(event), do: WorkAccess.check_in_tx(event)

  defp input(ref, terminal?, opts) do
    case Ankole.Signals.get_signal(ref.signal_id) do
      {:ok, %Signal{} = snapshot} ->
        with true <- same_input?(snapshot, ref),
             :ok <- input_open(snapshot, terminal?),
             :ok <- admitted_access(snapshot),
             :ok <- Keyword.get(opts, :before_fence, fn -> :ok end).(),
             %Signal{} = event <- lock_input(snapshot, opts),
             true <- WorkAccess.fields(event) == WorkAccess.fields(snapshot),
             :ok <- input_open(event, terminal?) do
          :ok
        else
          {:error, _} = error -> error
          _ -> {:error, :run_closed}
        end

      _missing ->
        {:error, :run_closed}
    end
  end

  defp same_input?(%Signal{} = event, ref),
    do: event.agent_uid == ref.agent_uid and event.session_id == ref.session_id

  defp lock_input(snapshot, opts) do
    if Keyword.get(opts, :lock, false),
      do: Ankole.Signals.lock_signal_in_tx(snapshot.id),
      else: snapshot
  end

  defp input_open(event, terminal?) do
    if terminal? or event.status in [:queued, :running],
      do: :ok,
      else: {:error, :run_closed}
  end
end
