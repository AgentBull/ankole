defmodule Ankole.BackgroundAgentJobs.Lifecycle do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL

  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Text
  alias Ankole.BackgroundAgentJobs.Turns

  @max_running_per_agent 3
  @max_execution_attempts 5
  @max_consecutive_turn_failures 5
  @max_event_payload_bytes 16_384
  @artifact_path_limit 32
  @artifact_path_bytes 8_192
  @internal_uuid_pattern ~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i
  @path_handoff_keys [
    {"files_changed", :files_changed},
    {"artifacts", :artifacts},
    {"artifact_roots", :artifact_roots}
  ]
  @truncation_suffix "...[truncated]"
  @terminal_statuses Job.terminal_statuses()
  @running_statuses Job.running_statuses()

  @doc false
  @spec upsert_turn_from_worker(pos_integer(), String.t(), map(), TurnRef.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  def upsert_turn_from_worker(job_id, agent_uid, attrs, %TurnRef{} = turn_ref, route)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and is_map(attrs) and
             is_binary(route) do
    Repo.transact(fn repo ->
      with {:ok, :authorized} <-
             WorkerRouteAuth.authorize_turn_route_in_tx(repo, turn_ref, route, :write, lock: true),
           :ok <- lock_agent_slots(repo, agent_uid),
           %Job{} = job <-
             Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
           {:ok, turn} <- Turns.upsert_from_worker_in_tx(repo, job, attrs) do
        {:ok, turn}
      else
        nil -> {:error, :job_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec claim_attempt_in_tx(module(), pos_integer(), String.t(), pos_integer(), map()) ::
          {:ok, Job.t()} | {:error, term()}
  def claim_attempt_in_tx(repo, job_id, agent_uid, expected_attempt, turn_start_spec)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and expected_attempt > 0 and
             is_map(turn_start_spec) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{} = job <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
      claim_attempt(repo, job, expected_attempt, turn_start_spec)
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec claim_continuation_in_tx(module(), pos_integer(), String.t(), pos_integer(), map()) ::
          {:ok, Job.t()} | {:error, term()}
  def claim_continuation_in_tx(repo, job_id, agent_uid, expected_attempt, turn_start_spec)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and expected_attempt > 0 and
             is_map(turn_start_spec) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{} = job <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
      claim_continuation(repo, job, expected_attempt, turn_start_spec)
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec requeue_unstarted_attempt(pos_integer(), String.t(), pos_integer()) ::
          {:ok, Job.t()} | {:error, term()}
  def requeue_unstarted_attempt(job_id, agent_uid, expected_attempt)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and expected_attempt > 0 do
    Repo.transact(fn repo ->
      with :ok <- lock_agent_slots(repo, agent_uid),
           %Job{status: "running", attempts: ^expected_attempt} = job <-
             Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
        job
        |> Job.changeset(%{
          status: "queued",
          attempts: expected_attempt - 1,
          started_at: if(expected_attempt == 1, do: nil, else: job.started_at)
        })
        |> repo.update()
      else
        nil -> {:error, :job_not_found}
        %Job{} -> {:error, :background_agent_job_attempt_changed}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec requeue_credential_pool_exhausted_attempt_in_tx(
          module(),
          pos_integer(),
          String.t()
        ) ::
          {:ok, Job.t()} | {:error, term()}
  def requeue_credential_pool_exhausted_attempt_in_tx(repo, job_id, agent_uid)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{status: "running", attempts: attempts} = job when attempts > 0 <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
      job
      |> Job.changeset(%{
        status: "queued",
        attempts: attempts - 1,
        started_at: if(attempts == 1, do: nil, else: job.started_at)
      })
      |> repo.update()
    else
      nil -> {:error, :job_not_found}
      %Job{} -> {:error, :background_agent_job_attempt_changed}
      {:error, _reason} = error -> error
    end
  end

  @spec commit_status_with_wakeup(pos_integer(), String.t(), map(), keyword()) ::
          {:ok, %{job: Job.t(), wakeup_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def commit_status_with_wakeup(job_id, agent_uid, attrs, opts \\ [])
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and is_map(attrs) and
             is_list(opts) do
    result =
      with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
        now = now()

        Repo.transact(fn repo ->
          turn_ref = Keyword.get(opts, :turn_ref)

          commit_status_with_wakeup_in_tx(
            repo,
            job_id,
            agent_uid,
            attrs,
            now,
            turn_ref,
            Keyword.get(opts, :worker_route),
            Keyword.get(opts, :turn_interruption)
          )
        end)
      end

    result
  end

  @doc false
  @spec commit_status_with_wakeup_in_tx(
          module(),
          pos_integer(),
          String.t(),
          map(),
          DateTime.t(),
          Ankole.SignalsGateway.ActorRuntime.TurnRef.t() | nil,
          String.t() | nil,
          map() | nil
        ) ::
          {:ok, %{job: Job.t(), wakeup_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def commit_status_with_wakeup_in_tx(
        repo,
        job_id,
        agent_uid,
        attrs,
        %DateTime{} = now,
        turn_ref \\ nil,
        worker_route \\ nil,
        turn_interruption \\ nil
      ) do
    # Every transition locks any live worker/assignment prefix before taking the
    # agent/job locks. Worker writes additionally validate activation and
    # revision through their turn fence.
    with :ok <- lock_runtime_prefix_in_tx(repo, job_id, agent_uid, turn_ref, worker_route),
         {:ok, result} <-
           commit_status_after_runtime_prefix_in_tx(
             repo,
             job_id,
             agent_uid,
             attrs,
             now,
             turn_ref,
             turn_interruption
           ) do
      {:ok, result}
    end
  end

  @doc false
  @spec commit_status_after_runtime_prefix_in_tx(
          module(),
          pos_integer(),
          String.t(),
          map(),
          DateTime.t(),
          Ankole.SignalsGateway.ActorRuntime.TurnRef.t() | nil,
          map() | nil
        ) ::
          {:ok, %{job: Job.t(), wakeup_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def commit_status_after_runtime_prefix_in_tx(
        repo,
        job_id,
        agent_uid,
        attrs,
        %DateTime{} = now,
        turn_ref,
        turn_interruption \\ nil
      ) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{} = job <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
         attrs <- Attrs.normalize(attrs),
         attrs <- bound_result_path_handoffs(attrs),
         :ok <- enforce_status_transition(job, attrs),
         :ok <- enforce_running_limit(repo, job, attrs),
         :ok <- enforce_no_unapplied_terminal_steer(repo, job, attrs, turn_ref),
         :ok <-
           maybe_interrupt_active_turns(
             repo,
             job,
             turn_interruption || terminal_turn_interruption(attrs),
             now
           ),
         :ok <- enforce_turn_trajectory_completion(repo, job, attrs),
         {:ok, job} <-
           job
           |> Job.changeset(
             attrs
             |> preserve_metadata(job)
             |> lifecycle_timestamps(job, now)
           )
           |> repo.update(),
         :ok <- maybe_release_worker_assignment(repo, job, turn_ref),
         {:ok, wakeup_event} <- append_wakeup_event(repo, job, now),
         :ok <- maybe_nudge_queued_after_status_commit(repo, job, now, turn_ref) do
      {:ok, %{job: job, wakeup_event: wakeup_event}}
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp enforce_no_unapplied_terminal_steer(
         repo,
         %Job{} = job,
         %{"status" => status},
         %Ankole.SignalsGateway.ActorRuntime.TurnRef{} = turn_ref
       )
       when status in ["succeeded", "failed"] do
    unapplied? =
      ActorEvent
      |> where([event], event.agent_uid == ^job.agent_uid)
      |> where([event], event.session_id == ^BackgroundAgentJobs.job_session_id(job.id))
      |> where([event], event.type == "command.steer")
      |> where([event], event.input_state == "open")
      |> where([event], is_nil(event.completed_at))
      |> join(
        :left,
        [event],
        delivery in Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery,
        on:
          delivery.actor_event_id == event.id and delivery.state == "accepted" and
            delivery.activation_uid == ^turn_ref.activation_uid and
            delivery.actor_epoch == ^turn_ref.actor_epoch and
            delivery.actor_event_id_fence == ^turn_ref.actor_event_id
      )
      |> where([_event, delivery], is_nil(delivery.id))
      |> repo.exists?()

    if unapplied?, do: {:error, :background_agent_job_pending_steer}, else: :ok
  end

  defp enforce_no_unapplied_terminal_steer(_repo, %Job{}, _attrs, _turn_ref),
    do: :ok

  defp enforce_turn_trajectory_completion(
         repo,
         %Job{} = job,
         %{"status" => status}
       )
       when status in ["waiting_on_user", "succeeded"],
       do:
         Turns.ensure_lead_closed_for_current_attempt_in_tx(repo, job,
           require_turn: true,
           latest_status: if(status == "waiting_on_user", do: "interrupted", else: "completed"),
           latest_error_code: if(status == "waiting_on_user", do: "request_user_input"),
           require_pending_tool_call: if(status == "waiting_on_user", do: "request_user_input")
         )

  defp enforce_turn_trajectory_completion(
         repo,
         %Job{attempts: attempts} = job,
         %{"status" => status}
       )
       when attempts > 0 and status in ["failed", "stopped"],
       do: Turns.ensure_lead_closed_for_current_attempt_in_tx(repo, job)

  defp enforce_turn_trajectory_completion(_repo, %Job{}, _attrs), do: :ok

  defp terminal_turn_interruption(%{"status" => "succeeded"}) do
    %{
      "code" => "background_agent_job_succeeded",
      "summary" => "The Job completed before this runtime Turn reported completion."
    }
  end

  defp terminal_turn_interruption(%{"status" => "failed"} = attrs) do
    case Map.get(attrs, "error") do
      %{} = error ->
        case {Attrs.text(error, "code"), Attrs.text(error, "summary")} do
          {code, summary} when is_binary(code) and is_binary(summary) ->
            %{"code" => code, "summary" => summary}

          _invalid ->
            failed_turn_interruption()
        end

      _missing ->
        failed_turn_interruption()
    end
  end

  defp terminal_turn_interruption(%{"status" => "stopped"}) do
    %{
      "code" => "background_agent_job_stopped",
      "summary" => "The Job stopped before this runtime Turn reported completion."
    }
  end

  defp terminal_turn_interruption(_attrs), do: nil

  defp failed_turn_interruption do
    %{
      "code" => "background_agent_job_failed",
      "summary" => "The Job failed before this runtime Turn reported completion."
    }
  end

  defp maybe_interrupt_active_turns(
         repo,
         %Job{} = job,
         %{"code" => code, "summary" => summary} = error,
         %DateTime{} = now
       )
       when is_binary(code) and is_binary(summary) do
    Turns.interrupt_active_for_current_attempt_in_tx(repo, job, error, now)
  end

  defp maybe_interrupt_active_turns(_repo, %Job{}, nil, %DateTime{}), do: :ok

  defp lock_runtime_prefix_in_tx(
         repo,
         _job_id,
         _agent_uid,
         %TurnRef{} = turn_ref,
         route
       )
       when is_binary(route) do
    case WorkerRouteAuth.authorize_turn_route_in_tx(repo, turn_ref, route, :write, lock: true) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp lock_runtime_prefix_in_tx(repo, job_id, agent_uid, _turn_ref, _route) do
    actor_key = %{agent_uid: agent_uid, session_id: BackgroundAgentJobs.job_session_id(job_id)}

    with :ok <- WorkerPool.lock_actor_assignment_in_tx(repo, actor_key) do
      case live_assignment_snapshot(repo, actor_key) do
        %ActorSessionWorkerAssignment{} = assignment ->
          _worker = lock_assignment_worker(repo, assignment.worker_id)
          _assignment = lock_live_assignment(repo, assignment, actor_key)
          :ok

        nil ->
          :ok
      end
    end
  end

  defp live_assignment_snapshot(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.one()
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

  @doc false
  @spec nudge_queued_after_slot_release(module(), Job.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def nudge_queued_after_slot_release(repo, %Job{status: status} = job, now)
      when status in @terminal_statuses or status == "waiting_on_user" do
    Job
    |> where([row], row.agent_uid == ^job.agent_uid)
    |> where([row], row.status == "queued")
    |> select([row], {row.id, row.agent_uid})
    |> repo.all()
    |> Enum.reduce_while(:ok, fn {job_id, agent_uid}, :ok ->
      case RuntimeEvents.notify_actor_session_ready(
             repo,
             agent_uid,
             BackgroundAgentJobs.job_session_id(job_id),
             now
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def nudge_queued_after_slot_release(_repo, %Job{}, _now), do: :ok

  @doc false
  @spec finalize_worker_turn_in_tx(module(), TurnRef.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def finalize_worker_turn_in_tx(
        repo,
        %TurnRef{agent_uid: agent_uid, session_id: session_id},
        %DateTime{} = now
      ) do
    case BackgroundAgentJobs.parse_job_session_id(session_id) do
      :error ->
        :ok

      {:ok, job_id} ->
        case Queries.get_for_agent(repo, job_id, agent_uid, []) do
          %Job{status: status} = job
          when status in @terminal_statuses or status == "waiting_on_user" ->
            with :ok <- release_worker_assignment(repo, job),
                 :ok <- nudge_queued_after_slot_release(repo, job, now) do
              :ok
            end

          %Job{} ->
            :ok

          nil ->
            WorkerPool.release_assignment_for_actor_in_tx(repo, %{
              agent_uid: agent_uid,
              session_id: session_id
            })
        end
    end
  end

  defp maybe_nudge_queued_after_status_commit(_repo, %Job{}, _now, %TurnRef{}),
    do: :ok

  defp maybe_nudge_queued_after_status_commit(repo, %Job{} = job, now, nil),
    do: nudge_queued_after_slot_release(repo, job, now)

  defp maybe_release_worker_assignment(_repo, %Job{}, %TurnRef{}), do: :ok

  defp maybe_release_worker_assignment(repo, %Job{status: "stopped"} = job, nil) do
    case live_worker_assignment?(repo, job) do
      true -> :ok
      false -> release_worker_assignment(repo, job)
    end
  end

  defp maybe_release_worker_assignment(repo, %Job{status: status} = job, _turn_ref)
       when status in @terminal_statuses or status == "waiting_on_user" do
    release_worker_assignment(repo, job)
  end

  defp maybe_release_worker_assignment(_repo, %Job{}, _turn_ref), do: :ok

  defp release_worker_assignment(repo, job) do
    WorkerPool.release_assignment_for_actor_in_tx(repo, %{
      agent_uid: job.agent_uid,
      session_id: BackgroundAgentJobs.job_session_id(job.id)
    })
  end

  defp live_worker_assignment?(repo, job) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^job.agent_uid)
    |> where([assignment], assignment.session_id == ^BackgroundAgentJobs.job_session_id(job.id))
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.exists?()
  end

  defp claim_attempt(_repo, %Job{status: status} = job, _expected_attempt, _turn_start_spec)
       when status in @terminal_statuses,
       do: {:error, {:background_agent_job_terminal, job}}

  defp claim_attempt(_repo, %Job{attempts: attempts}, _expected_attempt, _turn_start_spec)
       when attempts >= @max_execution_attempts,
       do: {:error, :background_agent_job_attempts_exhausted}

  defp claim_attempt(_repo, %Job{attempts: attempts}, expected_attempt, _turn_start_spec)
       when attempts + 1 != expected_attempt,
       do: {:error, :background_agent_job_attempt_changed}

  defp claim_attempt(repo, %Job{} = job, expected_attempt, turn_start_spec) do
    start_attempt(repo, job, expected_attempt, turn_start_spec)
  end

  defp claim_continuation(
         _repo,
         %Job{status: "stopped"} = job,
         _expected_attempt,
         _turn_start_spec
       ),
       do: {:error, {:background_agent_job_terminal, job}}

  defp claim_continuation(_repo, %Job{attempts: attempts}, expected_attempt, _turn_start_spec)
       when attempts + 1 != expected_attempt,
       do: {:error, :background_agent_job_attempt_changed}

  # A continuation is deliberately not capped by @max_execution_attempts,
  # because every steer of a live Job starts one. The cap that matters here is
  # progress: when the lead thread only produces failures, each redelivered
  # steer event starts another attempt against the same broken dependency, so
  # the Job burns tokens for hours and the real cause never reaches the user.
  defp claim_continuation(repo, %Job{} = job, expected_attempt, turn_start_spec) do
    case Turns.consecutive_lead_failures_in_tx(repo, job, @max_consecutive_turn_failures) do
      {count, error} when count >= @max_consecutive_turn_failures ->
        {:error, {:background_agent_job_turn_failures_exhausted, error}}

      _below_limit ->
        start_attempt(repo, job, expected_attempt, turn_start_spec)
    end
  end

  defp start_attempt(repo, %Job{} = job, expected_attempt, turn_start_spec) do
    if job.status not in @running_statuses and
         running_count(repo, job.agent_uid, job.id) >= @max_running_per_agent do
      {:error, :background_agent_job_agent_at_capacity}
    else
      now = now()

      with :ok <- Turns.interrupt_before_attempt_in_tx(repo, job, expected_attempt, now),
           {:ok, runtime_projection} <-
             ensure_runtime_projection(repo, job, turn_start_spec) do
        job
        |> Job.changeset(%{
          status: "running",
          attempts: expected_attempt,
          started_at: job.started_at || now,
          completed_at: nil,
          metadata: Map.delete(job.metadata || %{}, "pending_user_input"),
          runtime_projection: runtime_projection
        })
        |> repo.update()
      end
    end
  end

  defp ensure_runtime_projection(_repo, %Job{runtime_projection: %{} = projection}, _spec),
    do: {:ok, projection}

  defp ensure_runtime_projection(repo, %Job{} = job, %{} = turn_start_spec),
    do: RuntimeProjection.capture(repo, job.agent_uid, turn_start_spec)

  defp append_wakeup_event(repo, %Job{} = job, now) do
    case wakeup_event_type(job.status) do
      nil ->
        {:ok, nil}

      event_type ->
        source_event_id = wakeup_source_event_id(job)
        reply_route = job.reply_route || %{}

        with binding_name when is_binary(binding_name) <- Attrs.text(reply_route, "binding_name") do
          SignalsGateway.append_actor_event_in_tx(repo, %{
            agent_uid: job.agent_uid,
            binding_name: binding_name,
            session_id: job.owner_session_id,
            source_event_id: source_event_id,
            signal_channel_id: Map.get(reply_route, "signal_channel_id"),
            provider_thread_id: Map.get(reply_route, "provider_thread_id"),
            source_entry_id: Map.get(reply_route, "source_entry_id"),
            type: event_type,
            available_at: now,
            payload: wakeup_payload(job, source_event_id, event_type, now)
          })
        else
          nil -> {:error, :background_agent_job_reply_route_binding_missing}
        end
    end
  end

  defp wakeup_event_type("succeeded"), do: "background_agent_job.completed"
  defp wakeup_event_type("failed"), do: "background_agent_job.failed"
  defp wakeup_event_type("waiting_on_user"), do: "background_agent_job.waiting"
  defp wakeup_event_type(_status), do: nil

  defp wakeup_source_event_id(%Job{status: "waiting_on_user"} = job) do
    "background_agent_job:#{job.id}:waiting:#{job.attempts}"
  end

  defp wakeup_source_event_id(%Job{} = job) do
    "background_agent_job:#{job.id}:#{job.status}:#{job.attempts}"
  end

  defp wakeup_payload(job, source_event_id, event_type, now) do
    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://background-agent-job",
      "subject" => "background-agent-job:#{job.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => event_type,
      "data" =>
        Attrs.reject_nil_values(%{
          "job_id" => job.id,
          "title" => job.title,
          "status" => job.status,
          "workspace_template_id" => job.workspace_template_id,
          "attempts" => job.attempts,
          "result_summary" => result_summary(job),
          "delivery_status" => delivery_status(job),
          "delivery_issue_count" => delivery_issue_count(job),
          "artifacts" => bounded_path_handoff(Map.get(job.result || %{}, "artifacts")),
          "artifact_roots" => bounded_path_handoff(Map.get(job.result || %{}, "artifact_roots")),
          "project_path" => Map.get(job.result || %{}, "project_path"),
          "reply_route" => job.reply_route || %{},
          "pending_user_input" => get_in(job.metadata || %{}, ["pending_user_input"])
        })
    }
  end

  defp result_summary(%Job{status: "succeeded", result: result}) do
    result
    |> map_summary([{"summary", :summary}, {"output_text", :output_text}])
    |> truncate_summary()
  end

  defp result_summary(%Job{status: "failed", error: error}) do
    error
    |> map_summary([
      {"summary", :summary},
      {"reason", :reason},
      {"message", :message},
      {"code", :code}
    ])
    |> remove_internal_uuid_tokens()
    |> truncate_summary()
  end

  defp result_summary(%Job{}), do: nil

  defp delivery_status(%Job{result: %{"verification" => verification}})
       when is_map(verification),
       do: Map.get(verification, "status")

  defp delivery_status(%Job{}), do: nil

  defp delivery_issue_count(%Job{result: result}) when is_map(result) do
    verification = Map.get(result, "verification")

    case if(is_map(verification), do: Map.get(verification, "issues")) do
      issues when is_list(issues) and issues != [] -> length(issues)
      _value -> nil
    end
  end

  defp delivery_issue_count(%Job{}), do: nil

  defp bound_result_path_handoffs(%{"result" => result} = attrs) when is_map(result) do
    result =
      Enum.reduce(@path_handoff_keys, result, fn {key, atom_key}, bounded ->
        case Map.fetch(bounded, key) do
          {:ok, value} ->
            bounded
            |> Map.delete(atom_key)
            |> Map.put(key, bounded_path_handoff(value))

          :error ->
            case Map.fetch(bounded, atom_key) do
              {:ok, value} ->
                bounded
                |> Map.delete(atom_key)
                |> Map.put(key, bounded_path_handoff(value))

              :error ->
                bounded
            end
        end
      end)

    Map.put(attrs, "result", result)
  end

  defp bound_result_path_handoffs(attrs), do: attrs

  defp bounded_path_handoff(paths) when is_list(paths),
    do: build_path_handoff(paths, nil, false)

  defp bounded_path_handoff(%{} = handoff) do
    build_path_handoff(
      path_handoff_value(handoff, "paths", :paths, []),
      path_handoff_value(handoff, "total_count", :total_count),
      path_handoff_value(handoff, "truncated", :truncated) == true
    )
  end

  defp bounded_path_handoff(_value), do: nil

  defp build_path_handoff(paths, declared_total, declared_truncated) when is_list(paths) do
    observed_count = length(paths)
    paths = Enum.filter(paths, &(is_binary(&1) and &1 != ""))
    invalid_paths = length(paths) != observed_count
    total_count = max(observed_count, valid_total_count(declared_total))

    {selected, _serialized_bytes} =
      Enum.reduce_while(paths, {[], 2}, fn path, {selected, serialized_bytes} ->
        if path in selected do
          {:cont, {selected, serialized_bytes}}
        else
          if length(selected) >= @artifact_path_limit do
            {:halt, {selected, serialized_bytes}}
          else
            added_bytes =
              byte_size(Ankole.JSON.encode!(path)) + if(selected == [], do: 0, else: 1)

            if serialized_bytes + added_bytes <= @artifact_path_bytes do
              {:cont, {[path | selected], serialized_bytes + added_bytes}}
            else
              {:cont, {selected, serialized_bytes}}
            end
          end
        end
      end)

    selected = Enum.reverse(selected)

    %{
      "total_count" => total_count,
      "paths" => selected,
      "truncated" => declared_truncated or invalid_paths or length(selected) < total_count
    }
  end

  defp build_path_handoff(_paths, declared_total, _declared_truncated),
    do: build_path_handoff([], declared_total, true)

  defp valid_total_count(value) when is_integer(value) and value >= 0, do: value
  defp valid_total_count(_value), do: 0

  defp path_handoff_value(handoff, key, atom_key, default \\ nil) do
    case Map.fetch(handoff, key) do
      {:ok, value} -> value
      :error -> Map.get(handoff, atom_key, default)
    end
  end

  defp map_summary(value, preferred_keys) when is_map(value) do
    preferred_keys
    |> Enum.find_value(fn {string_key, atom_key} ->
      case Map.get(value, string_key) || Map.get(value, atom_key) do
        text when is_binary(text) and text != "" -> text
        _value -> nil
      end
    end)
  end

  defp map_summary(_value, _preferred_keys), do: nil

  defp remove_internal_uuid_tokens(nil), do: nil

  defp remove_internal_uuid_tokens(text) when is_binary(text),
    do: Regex.replace(@internal_uuid_pattern, text, "[internal-id]")

  defp truncate_summary(nil), do: nil

  defp truncate_summary(summary) when is_binary(summary) do
    if byte_size(summary) <= @max_event_payload_bytes do
      summary
    else
      Text.truncate_utf8(summary, @max_event_payload_bytes, @truncation_suffix)
    end
  end

  defp lock_agent_slots(repo, agent_uid) do
    lock_key = "background_agent_jobs:running_slots:#{agent_uid}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enforce_running_limit(repo, %Job{} = job, attrs) do
    status = Map.get(attrs, "status")

    cond do
      status not in @running_statuses ->
        :ok

      job.status in @running_statuses ->
        :ok

      running_count(repo, job.agent_uid, job.id) < @max_running_per_agent ->
        :ok

      true ->
        {:error, {:background_agent_job_agent_running_limit_exceeded, @max_running_per_agent}}
    end
  end

  defp enforce_status_transition(%Job{status: current}, attrs) do
    case Map.get(attrs, "status") do
      nil ->
        {:error, :background_agent_job_status_missing}

      next
      when next in @terminal_statuses and current in @terminal_statuses and next != current ->
        {:error, :background_agent_job_terminal}

      next ->
        if Job.transition_allowed?(current, next) do
          :ok
        else
          {:error, {:invalid_background_agent_job_status_transition, current, next}}
        end
    end
  end

  defp preserve_metadata(attrs, %Job{metadata: metadata}) do
    case Map.get(attrs, "metadata") do
      %{} = next_metadata -> Map.put(attrs, "metadata", Map.merge(metadata || %{}, next_metadata))
      _value -> attrs
    end
  end

  defp running_count(repo, agent_uid, job_id) do
    repo.aggregate(
      from(job in Job,
        where:
          job.agent_uid == ^agent_uid and job.status in ^@running_statuses and
            job.id != ^job_id
      ),
      :count
    )
  end

  defp lifecycle_timestamps(attrs, job, now) do
    case Map.get(attrs, "status") do
      status when status in @running_statuses ->
        Map.put_new(attrs, "started_at", job.started_at || now)

      status when status in @terminal_statuses ->
        attrs
        |> Map.put_new("started_at", job.started_at || now)
        |> Map.put_new("completed_at", now)

      _status ->
        attrs
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
