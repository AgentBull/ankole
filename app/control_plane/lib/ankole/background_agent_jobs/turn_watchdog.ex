defmodule Ankole.BackgroundAgentJobs.TurnWatchdog do
  @moduledoc "Detects a stalled Job from durable Codex trajectory activity."
  import Ecto.Query
  alias Ankole.{BackgroundAgentJobs, Repo}
  alias Ankole.BackgroundAgentJobs.{Lifecycle, Queries, Turns, Schemas.Job, Schemas.Turn}
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.{AgentWorkers, TurnControl}
  alias Ankole.Conversations.{CodexJob, JobTurnRef}
  @stall_grace_seconds 3_600
  @max_stalls 3
  @stall_code "background_agent_job_turn_stalled"
  @stall_message "runtime Turn recorded no durable progress before the stall deadline"

  @doc "Returns the silence a runtime Turn may keep before it counts as stalled."
  @spec stall_grace_seconds() :: pos_integer()
  def stall_grace_seconds, do: @stall_grace_seconds

  @doc "Returns the durable error code written on a Turn the watchdog interrupted."
  @spec stall_code() :: String.t()
  def stall_code, do: @stall_code

  @doc "Returns the durable summary written on a Turn the watchdog interrupted."
  @spec stall_summary() :: String.t()
  def stall_summary, do: @stall_message

  def reconcile_stuck_job(job_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    plan =
      Repo.transact(fn repo ->
        case Queries.get(job_id) do
          %Job{status: "running"} = job ->
            _worker = AgentWorkers.lock_in_tx(repo, job.agent_uid)
            :ok = Lifecycle.lock_agent_slots(repo, job.agent_uid)
            job = Queries.get_for_agent(repo, job.id, job.agent_uid, lock: "FOR UPDATE")
            # A Worker can accept an attempt and fail before its first trajectory.
            # The claim time bounds that gap without another deadline owner.
            activity = latest_active_turn_activity(repo, job.id) || job.updated_at

            event =
              repo.one(
                from e in ActorEvent,
                  where:
                    e.agent_uid == ^job.agent_uid and
                      e.session_id == ^BackgroundAgentJobs.job_session_id(job.id) and
                      e.input_state == "open" and is_nil(e.completed_at),
                  order_by: [asc: e.queue_sequence],
                  limit: 1
              )

            if (job.status == "running" and activity) && event && stalled?(activity, now) do
              ref = %JobTurnRef{
                agent_uid: job.agent_uid,
                session_id: event.session_id,
                actor_event_id: event.id,
                job_id: job.id,
                attempt: job.attempts
              }

              {:ok, {ref, stall_count(repo, job.id) + 1}}
            else
              {:ok, :live}
            end

          _ ->
            {:ok, :no_active_turn}
        end
      end)

    case plan do
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
  Closes the runtime Turns of one stalled attempt inside the abort transaction.

  A retryable stall keeps its actor event open, so only the Turn rows close.
  Recording the stall code on them is what lets a later stall count the earlier
  ones instead of retrying forever. An exhausted stall arrives here as a
  dead-letter event and follows the ordinary Job failure compensation.
  """
  @spec compensate_in_tx(module(), ActorEvent.t(), map(), DateTime.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def compensate_in_tx(
        repo,
        %ActorEvent{agent_uid: agent_uid, session_id: session_id, input_state: "open"},
        %{"code" => @stall_code, "message" => message},
        %DateTime{} = now
      ) do
    with {:ok, job_id} <- BackgroundAgentJobs.parse_job_session_id(session_id),
         %Job{} = job <- Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
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

  def compensate_in_tx(repo, %ActorEvent{} = event, reason, %DateTime{} = now),
    do: BackgroundAgentJobs.compensate_turn_error_in_tx(repo, event, reason, now)

  defp stall_count(repo, job_id) do
    Turn
    |> where([turn], turn.job_id == ^job_id)
    |> where([turn], fragment("?->>'code'", turn.error) == ^@stall_code)
    |> select([turn], count(turn.attempt, :distinct))
    |> repo.one()
  end

  defp latest_active_turn_activity(repo, job_id) do
    active_turn_activity_query()
    |> where([turn], turn.job_id == ^job_id)
    |> repo.one()
    |> case do
      {_job_id, %DateTime{} = activity} -> activity
      nil -> nil
    end
  end

  defp active_turn_activity_query do
    Turn
    |> where([turn], turn.status == "in_progress")
    |> group_by([turn], turn.job_id)
    |> select([turn], {turn.job_id, max(turn.updated_at)})
  end

  defp stalled?(%DateTime{} = activity, now),
    do: DateTime.compare(stall_deadline(activity), now) != :gt

  defp stall_deadline(%DateTime{} = activity),
    do: DateTime.add(activity, @stall_grace_seconds, :second)
end
