defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobDispatch do
  @moduledoc false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.RuntimeCommand
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobTurn
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @retry_delay_seconds 30

  def process(actor_key, %ActorEvent{} = event, opts) do
    with {:ok, job_id} <- job_id(event),
         %Job{} = job <-
           BackgroundAgentJobs.get_job_for_agent(job_id, actor_key.agent_uid) do
      dispatch_existing(actor_key, event, job, opts)
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  def process_steer(actor_key, %ActorEvent{} = event, opts) do
    with {:ok, job_id} <- job_id(event),
         %Job{} = job <-
           BackgroundAgentJobs.get_job_for_agent(job_id, actor_key.agent_uid) do
      case TurnLifecycle.live_delivery_for_session?(Ankole.Repo, actor_key) do
        true ->
          RuntimeCommand.process_steer_command(
            actor_key,
            event,
            BackgroundAgentJobTurn.opts(event, job, opts)
          )

        false ->
          process_inactive_steer(actor_key, event, job, opts)
      end
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp process_inactive_steer(actor_key, event, job, opts) do
    cond do
      job.status == "stopped" ->
        complete_without_turn(event, job)

      true ->
        with :ok <-
               BackgroundAgentJobs.complete_open_dispatch(job.id, job.agent_uid) do
          RuntimeCommand.process_steer_command(
            actor_key,
            event,
            continuation_opts(event, job, opts)
          )
          |> handle_start_result(event, job, opts)
        end
    end
  end

  defp dispatch_existing(actor_key, event, job, opts) do
    cond do
      job.status in Job.terminal_statuses() ->
        complete_without_turn(event, job)

      job.attempts >= 3 ->
        fail_exhausted(event, job.id, job.agent_uid)

      true ->
        start_turn(actor_key, event, job, opts)
    end
  end

  defp start_turn(actor_key, event, job, opts) do
    result =
      actor_key
      |> TurnLifecycle.start_worker_turn(event, attempt_opts(event, job, opts))
      |> handle_start_result(event, job, opts)

    replay_pending_steers(result, actor_key, event, job, opts)
  end

  defp attempt_opts(event, %Job{} = job, opts) do
    expected_attempt = job.attempts + 1
    claimed = %{job | attempts: expected_attempt}

    event
    |> BackgroundAgentJobTurn.opts(claimed, opts)
    |> Keyword.put(:admit_in_tx, fn repo ->
      case BackgroundAgentJobs.claim_attempt_in_tx(
             repo,
             job.id,
             job.agent_uid,
             expected_attempt
           ) do
        {:ok, %Job{}} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  defp continuation_opts(event, %Job{} = job, opts) do
    expected_attempt = job.attempts + 1
    claimed = %{job | attempts: expected_attempt}

    event
    |> BackgroundAgentJobTurn.opts(claimed, opts)
    |> Keyword.put(:admit_in_tx, fn repo ->
      case BackgroundAgentJobs.claim_continuation_in_tx(
             repo,
             job.id,
             job.agent_uid,
             expected_attempt
           ) do
        {:ok, %Job{}} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  defp replay_pending_steers(
         {:ok, %{send_outcome: "sent_or_queued"} = result},
         actor_key,
         event,
         job,
         opts
       ) do
    outcome =
      with {:ok, pending_events} <-
             BackgroundAgentJobs.pending_steer_events(
               job.id,
               job.agent_uid,
               event.id
             ) do
        replay_steers(actor_key, pending_events, job, opts)
      end

    case outcome do
      {:ok, replayed} -> {:ok, Map.put(result, :replayed_steers, replayed)}
      {:error, reason} -> {:ok, Map.put(result, :steer_replay_error, reason)}
    end
  end

  defp replay_pending_steers(result, _actor_key, _event, _job, _opts), do: result

  defp replay_steers(actor_key, events, job, opts) do
    Enum.reduce_while(events, {:ok, 0}, fn event, {:ok, count} ->
      case RuntimeCommand.process_steer_command(
             actor_key,
             event,
             BackgroundAgentJobTurn.opts(event, job, opts)
           ) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp handle_start_result({:error, :no_worker_available}, event, _job, opts),
    do: defer(event, :worker_capacity, opts)

  defp handle_start_result({:error, :background_agent_job_agent_at_capacity}, event, _job, opts),
    do: defer(event, :agent_capacity, opts)

  defp handle_start_result(
         {:error, :background_agent_job_codex_account_at_capacity},
         event,
         _job,
         opts
       ),
       do: defer(event, :codex_account_capacity, opts)

  defp handle_start_result(
         {:ok, %{send_outcome: outcome}},
         event,
         job,
         opts
       )
       when outcome != "sent_or_queued" do
    expected_attempt = job.attempts + 1

    with {:ok, _job} <-
           BackgroundAgentJobs.requeue_unstarted_attempt(
             job.id,
             job.agent_uid,
             expected_attempt
           ) do
      defer(event, :worker_delivery, opts)
    end
  end

  defp handle_start_result(
         {:error, {:background_agent_job_terminal, %Job{} = job}},
         event,
         _stale_job,
         _opts
       ),
       do: complete_without_turn(event, job)

  defp handle_start_result(
         {:error, :background_agent_job_attempts_exhausted},
         event,
         job,
         _opts
       ),
       do: fail_exhausted(event, job.id, job.agent_uid)

  defp handle_start_result(result, _event, _job, _opts), do: result

  defp defer(event, reason, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    available_at = DateTime.add(now, @retry_delay_seconds, :second)

    with {:ok, event} <- BackgroundAgentJobs.defer_actor_event(event, available_at) do
      {:ok, %{status: :waiting_for_worker, reason: reason, actor_event: event}}
    end
  end

  defp fail_exhausted(event, job_id, agent_uid) do
    with {:ok, %{job: job}} <-
           BackgroundAgentJobs.commit_status_with_wakeup(
             job_id,
             agent_uid,
             %{
               "status" => "failed",
               "error" => %{
                 "code" => "attempts_exhausted",
                 "summary" => "Job could not be resumed after three execution attempts."
               }
             },
             turn_interruption: %{
               "code" => "attempts_exhausted",
               "summary" =>
                 "The control plane interrupted this runtime Turn after execution attempts were exhausted."
             }
           ),
         {:ok, event} <- BackgroundAgentJobs.complete_actor_event(event) do
      {:ok, %{status: :attempts_exhausted, job: job, actor_event: event}}
    end
  end

  defp complete_without_turn(event, job) do
    with {:ok, event} <- BackgroundAgentJobs.complete_actor_event(event) do
      {:ok, %{status: :idle, job: job, actor_event: event}}
    end
  end

  defp job_id(%ActorEvent{session_id: "job:" <> job_id})
       when job_id != "",
       do: {:ok, job_id}

  defp job_id(%ActorEvent{}), do: {:error, :invalid_background_agent_job_session}
end
