defmodule Ankole.BackgroundAgentJobs.TurnWatchdog do
  @moduledoc false

  import Ecto.Query

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.TurnControl
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  # A Worker heartbeat and its activation lease only prove that the Worker
  # process is alive. Codex can stop producing runtime notifications while the
  # Worker keeps renewing both, which leaves the Job `running` and its Turn
  # `in_progress` for as long as the deployment lives. The Turn row's own
  # `updated_at` is the one clock that moves only on real runtime progress, so
  # it owns stall detection.
  #
  # The budget covers the longest legitimate silence: one model call, which the
  # AIGateway already fails after five minutes, or one foreground tool call. A
  # delegated child Turn keeps its own row, so its checkpoints keep the Job
  # clock alive while the lead Turn waits.
  @stall_grace_seconds 3_600
  @max_stalls 3
  @stall_code "background_agent_job_turn_stalled"
  @stall_message "runtime Turn recorded no durable progress before the stall deadline"
  @running_statuses Job.running_statuses()

  @doc "Returns the silence a runtime Turn may keep before it counts as stalled."
  @spec stall_grace_seconds() :: pos_integer()
  def stall_grace_seconds, do: @stall_grace_seconds

  @doc "Returns the durable error code written on a Turn the watchdog interrupted."
  @spec stall_code() :: String.t()
  def stall_code, do: @stall_code

  @doc "Returns the durable summary written on a Turn the watchdog interrupted."
  @spec stall_summary() :: String.t()
  def stall_summary, do: @stall_message

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    active_turn_activity_query()
    |> Repo.all()
    |> Enum.map(fn {job_id, activity} ->
      {RuntimeEvents.job_turn_deadline_channel(),
       %{
         "job_id" => job_id,
         "stuck_at" => RuntimeEvents.encode_datetime(stall_deadline(activity))
       }}
    end)
  end

  @doc """
  Arms the stall deadline for one Job from its own durable Turn activity.

  The deadline and its handler read the same clock, so a checkpoint that stores
  no change cannot push the deadline past the activity it reports.
  """
  @spec notify_deadline_in_tx(module(), pos_integer()) :: :ok | {:error, term()}
  def notify_deadline_in_tx(repo, job_id) when is_integer(job_id) do
    case latest_active_turn_activity(repo, job_id) do
      %DateTime{} = activity ->
        RuntimeEvents.notify_job_turn_deadline(repo, job_id, stall_deadline(activity))

      nil ->
        :ok
    end
  end

  @doc """
  Reconciles one stall deadline against the Job's current Turn activity.

  A stalled attempt is aborted through the ordinary worker-turn abort path, so
  the actor event stays open and retryable exactly as it does for a Worker
  reported failure. Repeated stalls make the abort non-retryable, which lets the
  existing dead-letter compensation fail the Job with the stall cause.
  """
  @spec reconcile_stuck_job(pos_integer(), keyword()) ::
          {:ok, :live | :no_active_turn | :no_live_activation | :job_not_found | :stalled}
          | {:error, term()}
  def reconcile_stuck_job(job_id, opts \\ []) when is_integer(job_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case Repo.transact(fn repo -> plan_in_tx(repo, job_id, now) end) do
      {:ok, {:stalled, plan}} -> abort_stalled_attempt(plan, now)
      {:ok, outcome} -> {:ok, outcome}
      {:error, _reason} = error -> error
    end
  end

  # The plan is a snapshot read and takes no Job row lock: every write it leads
  # to locks the activation again. A Job lock here would also invert the runtime
  # lock order, which takes the activation before the Job.
  defp plan_in_tx(repo, job_id, now) do
    case Queries.get(job_id) do
      nil ->
        {:ok, :job_not_found}

      %Job{status: status} when status not in @running_statuses ->
        {:ok, :no_active_turn}

      %Job{} = job ->
        case latest_active_turn_activity(repo, job.id) do
          nil ->
            {:ok, :no_active_turn}

          %DateTime{} = activity ->
            if stalled?(activity, now) do
              stall_plan(repo, job, activity, now)
            else
              with :ok <-
                     RuntimeEvents.notify_job_turn_deadline(
                       repo,
                       job.id,
                       stall_deadline(activity)
                     ),
                   do: {:ok, :live}
            end
        end
    end
  end

  # Without a live activation there is no runtime fence to supersede. The
  # activation and Worker deadlines own that recovery, so the stall watchdog
  # stays out of it instead of inventing a second owner.
  defp stall_plan(repo, %Job{} = job, activity, now) do
    actor_key = %{
      agent_uid: job.agent_uid,
      session_id: BackgroundAgentJobs.job_session_id(job.id)
    }

    case TurnLifecycle.lock_live_activation(repo, actor_key) do
      %ActorSessionActivation{current_actor_event_id: actor_event_id} = activation
      when is_binary(actor_event_id) ->
        turn_ref = TurnRef.from_activation(actor_key, activation)

        {:ok,
         {:stalled,
          %{
            turn_ref: turn_ref,
            controls: TurnControl.collect(live_deliveries(repo, turn_ref), :retry, @stall_code),
            stalls: stall_count(repo, job.id) + 1,
            silent_seconds: DateTime.diff(now, activity, :second)
          }}}

      _activation ->
        {:ok, :no_live_activation}
    end
  end

  defp abort_stalled_attempt(%{turn_ref: turn_ref} = plan, now) do
    with {:ok, _result} <-
           TurnLifecycle.handle_turn_abort(turn_ref, stall_reason(plan),
             now: now,
             async_work_unit: BackgroundAgentJobs,
             compensate_turn_error_in_tx: &__MODULE__.compensate_in_tx/4
           ) do
      TurnControl.dispatch(plan.controls)
      {:ok, :stalled}
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

  defp stall_reason(plan) do
    %{
      "code" => @stall_code,
      "message" => @stall_message,
      "details_json" => %{
        "runtime" => "control_plane",
        "retryable" => plan.stalls < @max_stalls,
        "silent_seconds" => plan.silent_seconds,
        "stalls" => plan.stalls
      }
    }
  end

  defp live_deliveries(repo, %TurnRef{} = turn_ref) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> repo.all()
  end

  # One stall aborts one attempt, but it marks every active Turn of that
  # attempt, so rows overcount events. Distinct attempts count stall events.
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
