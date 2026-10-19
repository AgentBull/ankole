defmodule Ankole.BackgroundAgentJobs.Lifecycle do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL

  alias Ankole.Signals.Signal
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.AgentWorkers.WorkerRouteAuth
  alias Ankole.AgentWorkers
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Dispatch
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Text

  @max_execution_attempts 5
  @max_claims 25
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
  @spec upsert_turn_from_worker(pos_integer(), String.t(), map(), JobTurnRef.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  def upsert_turn_from_worker(job_id, agent_uid, attrs, %JobTurnRef{} = turn_ref, worker_id)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and is_map(attrs) and
             is_binary(worker_id) do
    Repo.transact(fn repo ->
      with {:ok, :authorized} <-
             WorkerRouteAuth.authorize_turn_in_tx(repo, turn_ref, worker_id, :write, lock: true),
           :ok <- lock_agent_slots(repo, agent_uid),
           %Job{} = job <-
             Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
           {:ok, turn} <- Turns.upsert_from_worker_in_tx(repo, job, attrs),
           {:ok, _job} <- record_checkpoint_source_in_tx(repo, job, turn) do
        {:ok, turn}
      else
        nil -> {:error, :job_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Claims the next attempt of a Job inside the caller's transaction.

  `max_running_per_agent` is the resolved per-Agent cap. The caller resolves it
  before it opens the transaction, because an AppConfigure read reaches another
  process on another connection, which a transaction must not wait on.
  """
  @spec claim_attempt_in_tx(
          module(),
          pos_integer(),
          String.t(),
          pos_integer(),
          map(),
          pos_integer()
        ) ::
          {:ok, Job.t()} | {:error, term()}
  def claim_attempt_in_tx(
        repo,
        job_id,
        agent_uid,
        expected_attempt,
        turn_start_spec,
        max_running_per_agent
      )
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and expected_attempt > 0 and
             is_map(turn_start_spec) do
    with :ok <- Ankole.Principals.WorkAccess.check_record_in_tx(repo, Job, job_id),
         :ok <- lock_agent_slots(repo, agent_uid),
         %Job{} = job <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
      claim_attempt(repo, job, expected_attempt, turn_start_spec, max_running_per_agent)
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec claim_continuation_in_tx(
          module(),
          pos_integer(),
          String.t(),
          pos_integer(),
          map(),
          pos_integer()
        ) ::
          {:ok, Job.t()} | {:error, term()}
  def claim_continuation_in_tx(
        repo,
        job_id,
        agent_uid,
        expected_attempt,
        turn_start_spec,
        max_running_per_agent
      )
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and expected_attempt > 0 and
             is_map(turn_start_spec) do
    with :ok <- Ankole.Principals.WorkAccess.check_record_in_tx(repo, Job, job_id),
         :ok <- lock_agent_slots(repo, agent_uid),
         %Job{} = job <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
      claim_continuation(repo, job, expected_attempt, turn_start_spec, max_running_per_agent)
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec requeue_credential_pool_exhausted_attempt_in_tx(
          module(),
          pos_integer(),
          String.t()
        ) ::
          {:ok, Job.t()} | {:error, term()}
  # Pool exhaustion is AIGateway backpressure with a declared recovery time,
  # not the task failing, so it consumes no execution-failure budget. The
  # requeue keeps the claim, so a persistent storm runs into the total-claims
  # cap and fails with the infrastructure verdict instead of a task verdict.
  def requeue_credential_pool_exhausted_attempt_in_tx(repo, job_id, agent_uid)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{status: "running", attempts: attempts} = job when attempts > 0 <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
      job
      |> Job.changeset(%{status: "queued"})
      |> repo.update()
    else
      nil -> {:error, :job_not_found}
      %Job{} -> {:error, :background_agent_job_attempt_changed}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec requeue_retryable_attempt_in_tx(module(), pos_integer(), String.t(), keyword()) ::
          {:ok, Job.t() | nil} | {:error, term()}
  def requeue_retryable_attempt_in_tx(repo, job_id, agent_uid, opts \\ [])
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) do
    charge? = Keyword.get(opts, :charge, false)

    with :ok <- lock_agent_slots(repo, agent_uid) do
      case Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
        %Job{status: "running"} = job ->
          job
          |> Job.changeset(%{
            status: "queued",
            execution_failures: job.execution_failures + if(charge?, do: 1, else: 0)
          })
          |> repo.update()

        # A Job that already left `running` (stopped, completed, waiting, or
        # already requeued) needs no compensation; the abort stays a no-op.
        _job ->
          {:ok, nil}
      end
    end
  end

  @spec commit_status_with_wakeup(pos_integer(), String.t(), map(), keyword()) ::
          {:ok, %{job: Job.t(), wakeup_event: Signal.t() | nil}}
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
            Keyword.get(opts, :worker_id),
            Keyword.get(opts, :turn_interruption),
            Keyword.take(opts, [:external_completion, :applied_signal_ids])
          )
        end)
      end

    if not Repo.in_transaction?() do
      case result do
        {:ok, %{job: job}} ->
          Ankole.Sessions.job_turn(job)

        _error ->
          :ok
      end
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
          Ankole.Sessions.JobTurnRef.t() | nil,
          String.t() | nil,
          map() | nil
        ) ::
          {:ok, %{job: Job.t(), wakeup_event: Signal.t() | nil}}
          | {:error, term()}
  def commit_status_with_wakeup_in_tx(
        repo,
        job_id,
        agent_uid,
        attrs,
        %DateTime{} = now,
        turn_ref \\ nil,
        worker_id \\ nil,
        turn_interruption \\ nil,
        opts \\ []
      ) do
    # Every transition locks the Agent's Worker row before taking the agent/job
    # locks. Worker writes also validate the Job attempt and process identity.
    with :ok <- lock_runtime_prefix_in_tx(repo, agent_uid, turn_ref, worker_id),
         {:ok, result} <-
           commit_status_after_runtime_prefix_in_tx(
             repo,
             job_id,
             agent_uid,
             attrs,
             now,
             turn_ref,
             turn_interruption,
             opts
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
          Ankole.Sessions.JobTurnRef.t() | nil,
          map() | nil
        ) ::
          {:ok, %{job: Job.t(), wakeup_event: Signal.t() | nil}}
          | {:error, term()}
  def commit_status_after_runtime_prefix_in_tx(
        repo,
        job_id,
        agent_uid,
        attrs,
        %DateTime{} = now,
        turn_ref,
        turn_interruption \\ nil,
        opts \\ []
      ) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{} = job <- Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
      if match?(%JobTurnRef{}, turn_ref) and job.status != "running" do
        if job.attempts == turn_ref.attempt and job.status == Attrs.normalize(attrs)["status"],
          do: {:ok, %{job: job, wakeup_event: nil}},
          else: {:error, :background_agent_job_attempt_changed}
      else
        commit_running_status_in_tx(repo, job, attrs, now, turn_ref, turn_interruption, opts)
      end
    else
      nil -> {:error, :job_not_found}
      error -> error
    end
  end

  defp commit_running_status_in_tx(repo, job, attrs, now, turn_ref, turn_interruption, opts) do
    with attrs <- Attrs.normalize(attrs),
         attrs <- bound_result_path_handoffs(attrs),
         :ok <- enforce_status_transition(job, attrs),
         :ok <-
           maybe_interrupt_active_slots(
             repo,
             job,
             turn_interruption || terminal_turn_interruption(attrs),
             now
           ),
         :ok <- enforce_turn_trajectory_completion(repo, job, attrs, opts),
         {:ok, job} <-
           job
           |> Job.changeset(
             attrs
             |> preserve_metadata(job)
             |> lifecycle_timestamps(job, now)
           )
           |> repo.update(),
         {:ok, job} <- complete_applied_in_tx(repo, job, turn_ref, opts, now),
         {:ok, steer_outcome} <-
           resolve_open_steers_after_commit(repo, job, now, turn_ref, opts),
         {:ok, wakeup_event} <- conclude_job_transition(repo, job, now, steer_outcome) do
      {:ok,
       %{job: job, wakeup_event: wakeup_event, dispatch_event: steer_outcome[:dispatch_event]}}
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  # Open steers outside the terminal Turn's applied input prefix become one
  # successor Job in arrival order. The final Turn acknowledgement consumes the
  # applied prefix. Successor storage and completion of the remaining steers are
  # one transaction, so a storage failure leaves the source Job and steers open.
  # Failed and stopped commits, and an external completion, answer open steers
  # with the terminal notice itself.
  defp resolve_open_steers_after_commit(
         repo,
         %Job{status: "succeeded"} = job,
         now,
         _turn_ref,
         opts
       ) do
    open_steers = Dispatch.open_steer_events_in_tx(repo, job.id, job.agent_uid)
    steers = open_steers

    case steers do
      [] ->
        {:ok, nil}

      steers ->
        if Keyword.get(opts, :external_completion, false) do
          with :ok <- complete_steer_events_in_tx(repo, steers, now) do
            {:ok, nil}
          end
        else
          with {:ok, %{job: successor, dispatch_event: dispatch_event}} <-
                 Dispatch.seed_steer_successor_in_tx(repo, job, steers, now),
               :ok <- complete_steer_events_in_tx(repo, steers, now) do
            {:ok, %{successor_job_id: successor.id, dispatch_event: dispatch_event}}
          end
        end
    end
  end

  defp resolve_open_steers_after_commit(repo, %Job{status: status} = job, now, _turn_ref, _opts)
       when status in ["failed", "stopped"] do
    with :ok <-
           complete_steer_events_in_tx(
             repo,
             Dispatch.open_steer_events_in_tx(repo, job.id, job.agent_uid),
             now
           ) do
      {:ok, nil}
    end
  end

  defp resolve_open_steers_after_commit(_repo, %Job{}, _now, _turn_ref, _opts), do: {:ok, nil}

  defp complete_applied_in_tx(repo, job, %JobTurnRef{} = ref, opts, now)
       when job.status in ["waiting_on_user", "succeeded", "failed", "stopped"] do
    ids = Enum.uniq([ref.signal_id | Keyword.get(opts, :applied_signal_ids, [])])

    result =
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, applied} ->
        case Ankole.Signals.lock_signal_in_tx(repo, id) do
          %Signal{agent_uid: uid, session_id: session} = event
          when uid == ref.agent_uid and session == ref.session_id ->
            case Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, event, now) do
              {:ok, _} -> {:cont, {:ok, [event | applied]}}
              error -> {:halt, error}
            end

          _ ->
            {:halt, {:error, :invalid_applied_signal_id}}
        end
      end)

    with {:ok, applied} <- result, do: record_applied_source_in_tx(repo, job, applied)
  end

  defp complete_applied_in_tx(_repo, job, _ref, _opts, _now), do: {:ok, job}

  # The Worker's existing client:<Signal id> receipt is recorded only after
  # Codex accepts turn/start or turn/steer. Commit the source with that fenced
  # checkpoint, before a crash can resume the Job with its earlier request.
  defp record_checkpoint_source_in_tx(repo, job, turn) do
    if turn.runtime_thread_id == job.runtime_thread_id do
      ids = Turns.applied_signal_ids(turn)

      events =
        repo.all(
          from event in Signal,
            where:
              event.id in ^ids and event.agent_uid == ^job.agent_uid and
                event.session_id == ^Ankole.BackgroundAgentJobs.job_session_id(job.id)
        )

      record_applied_source_in_tx(repo, job, events)
    else
      {:ok, job}
    end
  end

  defp record_applied_source_in_tx(repo, job, events) do
    case Ankole.Conversations.Route.applied_human_source(job, events) do
      nil ->
        {:ok, job}

      id ->
        job
        |> Ecto.Changeset.change(metadata: Map.put(job.metadata, "applied_source_signal_id", id))
        |> repo.update()
    end
  end

  defp complete_steer_events_in_tx(_repo, [], _now), do: :ok

  defp complete_steer_events_in_tx(repo, steers, now) do
    Enum.reduce_while(steers, :ok, fn steer, :ok ->
      case Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, steer, now) do
        {:ok, _event} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # An external completion is an accountable override of the worker deliverable
  # contract: the caller has verified the outcome outside the runtime, so no
  # completed lead Turn is required.
  defp enforce_turn_trajectory_completion(_repo, %Job{}, _attrs, external_completion: true),
    do: :ok

  defp enforce_turn_trajectory_completion(
         repo,
         %Job{} = job,
         %{"status" => status},
         _opts
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
         %{"status" => status},
         _opts
       )
       when attempts > 0 and status in ["failed", "stopped"],
       do: Turns.ensure_lead_closed_for_current_attempt_in_tx(repo, job)

  defp enforce_turn_trajectory_completion(_repo, %Job{}, _attrs, _opts), do: :ok

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

  defp maybe_interrupt_active_slots(
         repo,
         %Job{} = job,
         %{"code" => code, "summary" => summary} = error,
         %DateTime{} = now
       )
       when is_binary(code) and is_binary(summary) do
    Turns.interrupt_active_for_current_attempt_in_tx(repo, job, error, now)
  end

  defp maybe_interrupt_active_slots(_repo, %Job{}, nil, %DateTime{}), do: :ok

  # A Worker write proves its turn with the connection's worker id; a turn
  # reference without one fails the turn check.
  defp lock_runtime_prefix_in_tx(repo, _agent_uid, %JobTurnRef{} = turn_ref, worker_id) do
    case WorkerRouteAuth.authorize_turn_in_tx(repo, turn_ref, worker_id, :terminal, lock: true) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp lock_runtime_prefix_in_tx(repo, agent_uid, nil, _worker_id) do
    _worker = AgentWorkers.lock_in_tx(repo, agent_uid)
    :ok
  end

  defp claim_attempt(
         _repo,
         %Job{status: status} = job,
         _expected_attempt,
         _turn_start_spec,
         _max_running
       )
       when status in @terminal_statuses,
       do: {:error, {:background_agent_job_terminal, job}}

  defp claim_attempt(
         _repo,
         %Job{execution_failures: failures},
         _expected_attempt,
         _turn_start_spec,
         _max_running
       )
       when failures >= @max_execution_attempts,
       do: {:error, :background_agent_job_attempts_exhausted}

  defp claim_attempt(
         _repo,
         %Job{attempts: attempts},
         _expected_attempt,
         _turn_start_spec,
         _max_running
       )
       when attempts >= @max_claims,
       do: {:error, :background_agent_job_claims_exhausted}

  defp claim_attempt(
         _repo,
         %Job{attempts: attempts},
         expected_attempt,
         _turn_start_spec,
         _max_running
       )
       when attempts + 1 != expected_attempt,
       do: {:error, :background_agent_job_attempt_changed}

  defp claim_attempt(repo, %Job{} = job, expected_attempt, turn_start_spec, max_running) do
    start_attempt(repo, job, expected_attempt, turn_start_spec, max_running)
  end

  defp claim_continuation(
         _repo,
         %Job{status: "stopped"} = job,
         _expected_attempt,
         _turn_start_spec,
         _max_running
       ),
       do: {:error, {:background_agent_job_terminal, job}}

  defp claim_continuation(
         _repo,
         %Job{attempts: attempts},
         _expected_attempt,
         _turn_start_spec,
         _max_running
       )
       when attempts >= @max_claims,
       do: {:error, :background_agent_job_claims_exhausted}

  defp claim_continuation(
         _repo,
         %Job{attempts: attempts},
         expected_attempt,
         _turn_start_spec,
         _max_running
       )
       when attempts + 1 != expected_attempt,
       do: {:error, :background_agent_job_attempt_changed}

  # A continuation is deliberately not capped by @max_execution_attempts,
  # because every steer of a live Job starts one. The cap that matters here is
  # progress: when the lead thread only produces failures, each redelivered
  # steer event starts another attempt against the same broken dependency, so
  # the Job burns tokens for hours and the real cause never reaches the user.
  defp claim_continuation(repo, %Job{} = job, expected_attempt, turn_start_spec, max_running) do
    case Turns.consecutive_lead_failures_in_tx(repo, job, @max_consecutive_turn_failures) do
      {count, error} when count >= @max_consecutive_turn_failures ->
        {:error, {:background_agent_job_turn_failures_exhausted, error}}

      _below_limit ->
        start_attempt(repo, job, expected_attempt, turn_start_spec, max_running)
    end
  end

  defp start_attempt(repo, %Job{} = job, expected_attempt, turn_start_spec, max_running) do
    if job.status not in @running_statuses and
         running_count(repo, job.agent_uid, job.id) >= max_running do
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

  defp ensure_runtime_projection(_repo, %Job{runtime_projection: %{} = projection}, %{}),
    do: {:ok, projection}

  defp ensure_runtime_projection(repo, %Job{} = job, %{} = turn_start_spec),
    do: RuntimeProjection.capture(repo, job.agent_uid, turn_start_spec)

  # A skill-lesson reflection is a system job: its end must wake no session.
  # A succeeded reflection instead enqueues the apply worker inside this
  # transaction, so lessons land only after the terminal status is durable.
  defp conclude_job_transition(
         _repo,
         %Job{metadata: %{"skill_lesson_reflection" => true}} = job,
         _now,
         _steer_outcome
       ) do
    if job.status == "succeeded" do
      {:ok, _oban_job} =
        %{"job_id" => job.id}
        |> Ankole.Brain.Jobs.ApplySkillLessons.new()
        |> Oban.insert()
    end

    {:ok, nil}
  end

  defp conclude_job_transition(repo, %Job{} = job, now, steer_outcome),
    do: append_wakeup_event(repo, job, now, steer_outcome)

  defp append_wakeup_event(repo, %Job{} = job, now, steer_outcome) do
    case wakeup_event_type(job.status) do
      nil ->
        {:ok, nil}

      event_type ->
        source_event_id = wakeup_source_event_id(job)
        reply_route = job.reply_route || %{}

        payload = wakeup_payload(job, source_event_id, event_type, now, steer_outcome)

        with true <-
               (is_binary(reply_route["binding_name"]) or
                  match?({:ok, _}, Ecto.UUID.cast(reply_route["conversation_id"]))) ||
                 {:error, :background_agent_job_reply_route_binding_missing} do
          Ankole.Signals.accept_in_tx(repo, %{
            producer: :kernel,
            source: payload["source"],
            id: source_event_id,
            type: event_type,
            subject: payload["subject"],
            time: now,
            data: payload["data"],
            target: %{agent_uid: job.agent_uid, session_id: job.owner_session_id},
            sender: nil,
            authorization: Ankole.Principals.WorkAccess.fields(job),
            reply_route: reply_route
          })
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

  defp wakeup_payload(job, source_event_id, event_type, now, steer_outcome) do
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
          "artifacts" => Map.get(job.result || %{}, "artifacts"),
          "artifact_roots" => Map.get(job.result || %{}, "artifact_roots"),
          "project_path" => Map.get(job.result || %{}, "project_path"),
          "reply_route" => job.reply_route || %{},
          "pending_user_input" => get_in(job.metadata || %{}, ["pending_user_input"]),
          "successor_job_id" => steer_outcome[:successor_job_id]
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

  def lock_agent_slots(repo, agent_uid) do
    lock_key = "background_agent_jobs:running_slots:#{agent_uid}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
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
      %{} = next_metadata ->
        Map.put(
          attrs,
          "metadata",
          Map.merge(metadata || %{}, Map.delete(next_metadata, "applied_source_signal_id"))
        )

      _value ->
        attrs
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

  def stop_human_work_in_tx(repo, uid, version, now) do
    repo.update_all(
      from(j in Job,
        where:
          j.human_uid == ^uid and j.human_access_version < ^version and
            j.status in ["queued", "waiting_on_user"]
      ),
      set: [
        status: "stopped",
        completed_at: now,
        updated_at: now,
        error: %{"code" => "human_access_revoked"}
      ]
    )
  end
end
