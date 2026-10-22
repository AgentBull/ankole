defmodule Ankole.AgentWorkers.WorkerRouteAuth do
  @moduledoc "Accepts Worker RPC only for its bound Agent and current durable input or Job attempt."
  alias Ankole.{Errors, Principals.WorkAccess}
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.RunRef
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers

  @doc """
  Authorizes one Worker RPC in its own transaction.

  The transaction takes the same locks as a terminal write, so the check
  waits for a concurrent cancellation or terminal write to commit.
  """
  def authorize_turn(ref, worker_id, effect),
    do: Errors.reason(AgentWorkers.authorize_worker_turn(ref, worker_id, effect))

  def authorize_turn_in_tx(repo, ref, worker_id, effect, opts \\ [])

  def authorize_turn_in_tx(repo, ref, uid, effect, opts)
      when effect in [:read, :write, :terminal] do
    case ref do
      %JobTurnRef{} ->
        # The locked Job and attempt fence serialize cancellation and terminal
        # writes. Lock the input only when its lifecycle mutation runs, after
        # Turn and Session locks.
        with :ok <- lock_job_write(repo, uid, effect),
             %Job{attempts: attempt, status: status} <-
               job(repo, ref, effect),
             true <- attempt == ref.attempt and (status == :running or effect == :terminal),
             :ok <- input(repo, ref, status != :running, Keyword.delete(opts, :lock)) do
          {:ok, :authorized}
        else
          {:error, _} = error -> error
          _ -> {:error, :background_agent_job_attempt_changed}
        end

      %RunRef{} ->
        with :ok <- input(repo, ref, false, opts), do: {:ok, :authorized}
    end
  end

  def authorize_turn_in_tx(_repo, _ref, _worker_id, _effect, _opts),
    do: {:error, :worker_not_assigned_to_turn}

  defp lock_job_write(_repo, _uid, :read), do: :ok

  defp lock_job_write(repo, uid, _effect) do
    AgentWorkers.lock_in_tx(repo, uid)
    Lifecycle.lock_agent_slots(repo, uid)
  end

  defp job(_repo, ref, :read),
    do: BackgroundAgentJobs.get_job_for_agent(ref.job_id, ref.agent_uid)

  defp job(repo, ref, _effect),
    do: BackgroundAgentJobs.lock_job_in_tx(repo, ref.job_id, ref.agent_uid)

  defp admitted_access(_repo, %{last_attempt_at: %DateTime{}}), do: :ok
  defp admitted_access(repo, event), do: WorkAccess.check_in_tx(repo, event)

  defp input(repo, ref, terminal?, opts) do
    case Ankole.Signals.Domain.get_signal(ref.signal_id) do
      {:ok, %Signal{} = snapshot} ->
        with true <- same_input?(snapshot, ref),
             :ok <- input_open(snapshot, terminal?),
             :ok <- admitted_access(repo, snapshot),
             %Signal{} = event <- lock_input(repo, snapshot, opts),
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

  defp lock_input(repo, snapshot, opts) do
    if Keyword.get(opts, :lock, false),
      do: Ankole.Signals.lock_signal_in_tx(repo, snapshot.id),
      else: snapshot
  end

  defp input_open(event, terminal?) do
    if terminal? or event.status in [:queued, :running],
      do: :ok,
      else: {:error, :run_closed}
  end
end
