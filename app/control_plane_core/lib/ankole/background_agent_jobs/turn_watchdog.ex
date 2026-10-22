defmodule Ankole.BackgroundAgentJobs.TurnWatchdog do
  @moduledoc "Detects a stalled Job from durable Codex trajectory activity."
  require Ash.Query
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.AgentWorkers
  alias Ankole.Sessions.TurnControl
  alias Ankole.Sessions.CodexJob
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.JobTurnRef
  @stall_grace_seconds 3_600
  @max_stalls 3
  @stall_code "background_agent_job_turn_stalled"
  @stall_message "runtime Turn recorded no durable progress before the stall deadline"

  @doc "Returns the durable error code written on a Turn the watchdog interrupted."
  @spec stall_code() :: String.t()
  def stall_code, do: @stall_code

  def reconcile_stuck_job(job_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case Ankole.Ash.run_action(Job, :inspect_stall, %{job_id: job_id, now: now}) do
      {:ok, {ref, stalls}} ->
        reason = %{
          "code" => @stall_code,
          "message" => @stall_message,
          "details_json" => %{"retryable" => stalls < @max_stalls, "stalls" => stalls}
        }

        with {:ok, _} <- CodexJob.abort(ref, ref.agent_uid, reason) do
          TurnControl.dispatch([
            %{turn_ref: ref, verb: :retry, reason: @stall_code, payload: %{}}
          ])

          {:ok, :stalled}
        end

      result ->
        result
    end
  end

  @doc """
  Reads the stall state of a running Job under the Worker, slot, and Job locks,
  inside the `inspect_stall` action of the Job.
  """
  @spec inspect_stall_in_tx(module(), pos_integer(), DateTime.t()) ::
          {:ok, {JobTurnRef.t(), pos_integer()} | :live | :no_active_turn}
  def inspect_stall_in_tx(repo, job_id, %DateTime{} = now) do
    case Queries.get(job_id) do
      %Job{status: :running} = job ->
        _worker = AgentWorkers.lock_in_tx(repo, job.agent_uid)
        :ok = Lifecycle.lock_agent_slots(repo, job.agent_uid)
        job = Queries.lock_for_agent_in_tx(job.id, job.agent_uid)
        # A Worker can accept an attempt and fail before its first trajectory.
        # The claim time bounds that gap without another deadline owner.
        activity = latest_active_turn_activity(job.id) || job.updated_at

        event =
          Ankole.Sessions.Queue.oldest_open(
            repo,
            job.agent_uid,
            BackgroundAgentJobs.job_session_id(job.id)
          )

        if (job.status == :running and activity) && event && stalled?(activity, now) do
          ref = %JobTurnRef{
            agent_uid: job.agent_uid,
            session_id: event.session_id,
            signal_id: event.id,
            job_id: job.id,
            attempt: job.attempts
          }

          {:ok, {ref, stall_count(job.id) + 1}}
        else
          {:ok, :live}
        end

      _ ->
        {:ok, :no_active_turn}
    end
  end

  @doc """
  Closes the runtime Turns of one stalled attempt inside the abort transaction.

  A retryable stall keeps its Signal open, so only the Turn rows close.
  Recording the stall code on them is what lets a later stall count the earlier
  ones instead of retrying forever. An exhausted stall arrives here as a
  dead-letter event and follows the ordinary Job failure compensation.
  """
  @spec compensate_in_tx(module(), Signal.t(), map(), DateTime.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def compensate_in_tx(
        repo,
        %Signal{agent_uid: agent_uid, session_id: session_id, status: live_status},
        %{"code" => @stall_code, "message" => message},
        %DateTime{} = now
      )
      when live_status in [:queued, :running] do
    with {:ok, job_id} <- BackgroundAgentJobs.parse_job_session_id(session_id),
         %Job{} = job <- Queries.lock_for_agent_in_tx(job_id, agent_uid),
         :ok <-
           Turns.interrupt_active_for_current_attempt_in_tx(
             repo,
             job,
             %{"code" => @stall_code, "summary" => message},
             now
           ),
         {:ok, requeued} <-
           Lifecycle.requeue_retryable_attempt_in_tx(repo, job.id, agent_uid, charge: true) do
      {:ok, %{kind: :turn_stall_interrupted, job: requeued || job}}
    else
      :error -> {:ok, nil}
      nil -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  def compensate_in_tx(repo, %Signal{} = event, reason, %DateTime{} = now),
    do: BackgroundAgentJobs.compensate_turn_error_in_tx(repo, event, reason, now)

  defp stall_count(job_id) do
    %{attempts: attempts} =
      Turn
      |> Ash.Query.filter(job_id == ^job_id and fragment("?->>'code'", error) == ^@stall_code)
      |> Ankole.Ash.aggregate!({:attempts, :count, field: :attempt, uniq?: true})

    attempts
  end

  defp latest_active_turn_activity(job_id) do
    Turn
    |> Ash.Query.filter(job_id == ^job_id and status == :in_progress)
    |> Ankole.Ash.max!(:updated_at)
  end

  defp stalled?(%DateTime{} = activity, now),
    do: DateTime.compare(stall_deadline(activity), now) != :gt

  defp stall_deadline(%DateTime{} = activity),
    do: DateTime.add(activity, @stall_grace_seconds, :second)
end
