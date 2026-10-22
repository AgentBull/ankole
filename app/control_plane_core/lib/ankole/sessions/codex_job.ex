defmodule Ankole.Sessions.CodexJob do
  @moduledoc "Admits or adopts a durable Job attempt. A Driver never owns the Codex execution."
  import Ecto.Query
  alias Ankole.{BackgroundAgentJobs, Repo}
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.WorkerWait
  alias Ankole.Sessions.Context
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue

  alias Ankole.AgentWorkers
  alias Ankole.Sessions.BackgroundAgentJobCap
  alias Ankole.Sessions.Workspaces
  alias Ankole.Sessions.TurnEnvelope
  alias Ankole.Sessions.TurnErrorClassifier
  alias Ankole.Sessions.TurnRuntimeEnv
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.AgentWorkers.WorkerRouteAuth

  alias Ankole.Sessions.SessionWorkspace

  defmodule Attempt do
    @moduledoc "One fenced observation of a durable Job attempt."
    @enforce_keys [
      :agent_uid,
      :session_id,
      :signal_id,
      :epoch,
      :event,
      :job,
      :job_ref,
      :job_worker,
      :job_mode
    ]
    defstruct [
      :agent_uid,
      :session_id,
      :signal_id,
      :epoch,
      :event,
      :delivered_event,
      :workspace_id,
      :spec,
      :context,
      :job,
      :job_ref,
      :job_worker,
      :job_mode,
      :span,
      kind: :job
    ]

    @type t :: %__MODULE__{}
  end

  @spec rebuild(map(), DateTime.t()) ::
          {:ok, :idle | %{event: Signal.t(), delay_ms: non_neg_integer()}}
  def rebuild(key, now \\ DateTime.utc_now(:microsecond)) do
    case Queue.oldest_open(Repo, key.agent_uid, key.session_id) do
      nil ->
        {:ok, :idle}

      %Signal{} = event ->
        {:ok,
         %{
           event: event,
           delay_ms: max(0, DateTime.diff(event.available_at, now, :millisecond))
         }}
    end
  end

  @spec admit(map(), Signal.t(), keyword()) :: {:ok, Attempt.t() | map()} | {:error, term()}
  def admit(_key, %Signal{producer: :external} = event, opts),
    do:
      Ankole.Sessions.Admission.reject_private_work_input(
        event,
        Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
      )

  def admit(key, event, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    ready_timeout_ms =
      Keyword.get_lazy(opts, :ready_timeout_ms, fn ->
        Ankole.AgentWorkers.Settings.current().ready_timeout_ms
      end)

    with {:ok, id} <- BackgroundAgentJobs.parse_job_session_id(key.session_id),
         %Job{} = snapshot <- BackgroundAgentJobs.get_job_for_agent(id, key.agent_uid) do
      prepared = Context.runtime(key, __MODULE__.opts(event, snapshot, opts))

      context =
        if snapshot.status == :running,
          do: {:ok, nil},
          else: Context.resolve(key.agent_uid, key.session_id)

      cap = BackgroundAgentJobCap.max_running_per_agent()

      admission = %{
        key: key,
        event: event,
        prepared: prepared,
        context: context,
        cap: cap,
        now: now,
        ready_timeout_ms: ready_timeout_ms
      }

      result =
        Repo.transact(fn repo ->
          # Lock Principal rows before AgentWorkers, SlotLock, and Job rows.
          access_result = admission_access(repo, event, snapshot)
          worker = AgentWorkers.lock_in_tx(repo, key.agent_uid)

          with :ok <- Lifecycle.lock_agent_slots(repo, key.agent_uid),
               %Job{} = job <- lock_job_in_tx(repo, id, key.agent_uid) do
            admit_locked_in_tx(repo, admission, job, worker, access_result)
          else
            nil -> {:error, :job_not_found}
            error -> error
          end
        end)

      admission_result(result, event, snapshot, now)
    else
      nil -> admission_result({:error, :job_not_found}, event, nil, now)
      error -> admission_result(error, event, nil, now)
    end
  end

  defp lock_job_in_tx(repo, id, agent_uid) do
    repo.one(
      from(j in Job,
        where: j.id == ^id and j.agent_uid == ^agent_uid,
        lock: "FOR UPDATE"
      ),
      lock_identity: {"background_agent_jobs", id}
    )
  end

  defp admit_locked_in_tx(
         repo,
         %{event: event, prepared: prepared} = admission,
         job,
         worker,
         access_result
       ) do
    cond do
      job.status in Job.terminal_statuses() ->
        with {:ok, event} <-
               Queue.mark_event_completed_in_tx(
                 repo,
                 event,
                 admission.now
               ),
             do: {:ok, %{status: :idle, signal: event}}

      access_result != :ok ->
        access_result

      match?({:error, _}, prepared) ->
        prepared

      true ->
        {:ok, spec} = prepared

        admit_attempt_in_tx(repo, admission, job, worker, spec)
    end
  end

  defp adopt_attempt?(%{last_attempt_at: %DateTime{}}, %{status: :running}), do: true
  defp adopt_attempt?(_event, _job), do: false

  defp admission_access(repo, event, job) do
    # Closing a terminal Job's trigger or adopting a live running attempt does not
    # admit new work.
    if adopt_attempt?(event, job) or job.status in Job.terminal_statuses() do
      :ok
    else
      with :ok <- Ankole.Tenants.check_work_admission_in_tx(repo, Repo.tenant_id!()),
           :ok <- WorkAccess.lock_authorizers_in_tx(repo, [event, job]),
           :ok <- WorkAccess.check_in_tx(repo, event),
           do: WorkAccess.check_in_tx(repo, job)
    end
  end

  defp admit_attempt_in_tx(
         repo,
         %{
           key: key,
           event: snapshot,
           context: context,
           now: now
         } = admission,
         job,
         worker,
         spec
       ) do
    mode = if job.status == :running, do: "adopt", else: "start"

    with {:ok, agent_context} <- start_context(mode, context) do
      case place_and_claim_in_tx(repo, snapshot, job, worker, spec, mode, admission) do
        {:wait, reason} ->
          with :ok <- Queue.lock_session_in_tx(repo, key.agent_uid, key.session_id),
               {:ok, event} <- current_input_in_tx(repo, key, snapshot, now) do
            WorkerWait.defer_in_tx(repo, event, reason, mode, now)
          end

        {:error, _reason} = error ->
          error

        {:ok, job, worker} ->
          with {:ok, agent_context} <- project_context(mode, agent_context, job),
               {:ok, _} <- Workspaces.ensure_in_tx(repo, key.agent_uid, key.session_id),
               %SessionWorkspace{} = workspace <- Fence.lock_workspace_in_tx(repo, key),
               {:ok, event} <- current_input_in_tx(repo, key, snapshot, now),
               {:ok, event} <-
                 Ankole.Ash.update(event, :start_attempt, %{
                   last_attempt_at: DateTime.utc_now(:microsecond)
                 }),
               {:ok, workspace} <-
                 Ankole.Ash.update(workspace, :advance_epoch, %{}),
               {:ok, spec} <-
                 Ankole.BackgroundAgentJobs.RuntimeProjection.turn_start_overrides(
                   job.runtime_projection
                 ) do
            # A running attempt's trigger precedes every unapplied steer. It stays open
            # until its terminal status commit, so adoption uses the same identity.
            ref = %JobTurnRef{
              agent_uid: key.agent_uid,
              session_id: key.session_id,
              signal_id: event.id,
              job_id: job.id,
              attempt: job.attempts
            }

            {:ok,
             %Attempt{
               agent_uid: key.agent_uid,
               session_id: key.session_id,
               signal_id: event.id,
               epoch: workspace.epoch,
               event: event,
               delivered_event: event,
               kind: :job,
               context: agent_context,
               workspace_id: workspace.id,
               spec:
                 Map.merge(spec, %{
                   workspace_id: workspace.id,
                   runtime_env: TurnRuntimeEnv.resolve(event),
                   # The Turn span and Worker use the claimed attempt identity.
                   request_context:
                     Map.merge(Map.get(spec, :request_context, %{}), %{
                       "session_id" => key.session_id,
                       "job_id" => job.id,
                       "attempts" => job.attempts
                     })
                 }),
               job: job,
               job_ref: ref,
               job_worker: worker,
               job_mode: mode
             }}
          else
            nil -> {:error, :input_unavailable}
            %Signal{} -> {:error, :input_unavailable}
            {:error, _} = error -> error
          end
      end
    end
  end

  defp current_input_in_tx(repo, key, snapshot, now) do
    with %Signal{id: head_id} <- Queue.oldest_open(repo, key.agent_uid, key.session_id),
         true <- head_id == snapshot.id,
         %Signal{status: live_status} = event
         when live_status in [:queued, :running] <-
           Ankole.Signals.lock_signal_in_tx(repo, snapshot.id),
         true <- event.agent_uid == key.agent_uid and event.session_id == key.session_id,
         true <- WorkAccess.fields(event) == WorkAccess.fields(snapshot) do
      if DateTime.compare(event.available_at, now) == :gt,
        do: {:error, {:input_not_due, event}},
        else: {:ok, event}
    else
      _unavailable -> {:error, :input_unavailable}
    end
  end

  defp place_and_claim_in_tx(_repo, _snapshot, job, worker, _spec, "adopt", _admission) do
    if is_nil(worker) or worker.state not in [:ready, :draining] do
      {:wait, :agent_worker_unavailable}
    else
      {:ok, job, worker}
    end
  end

  defp place_and_claim_in_tx(repo, snapshot, job, worker, spec, "start", admission) do
    capacity_available? = Lifecycle.capacity_available_in_tx?(repo, job, admission.cap)

    {status, started_at} =
      AgentWorkers.wait_status(
        worker,
        capacity_available?,
        job.worker_wait_started_at,
        admission.now,
        admission.ready_timeout_ms
      )

    with {:ok, job} <- WorkerWait.persist_in_tx(job, started_at, admission.now) do
      cond do
        status == :wait ->
          {:wait, :agent_worker_unavailable}

        not capacity_available? ->
          {:wait, :background_agent_job_agent_at_capacity}

        status == :timed_out ->
          {:wait, :agent_worker_ready_timeout}

        true ->
          reserve_and_claim_in_tx(repo, snapshot, job, spec, admission.cap)
      end
    end
  end

  defp reserve_and_claim_in_tx(repo, snapshot, job, spec, cap) do
    with {:ok, worker} <- AgentWorkers.reserve_slot_in_tx(repo, job.agent_uid),
         {:ok, job} <- claim(repo, snapshot, job, spec, cap) do
      {:ok, job, worker}
    else
      {:error, :no_worker_capacity} -> {:wait, :no_worker_capacity}
      error -> error
    end
  end

  defp project_context("adopt", _context, _job), do: {:ok, nil}
  defp project_context("start", context, job), do: Context.job(context, job)

  defp start_context("adopt", _context), do: {:ok, nil}
  defp start_context("start", {:ok, nil}), do: {:error, :input_unavailable}
  defp start_context("start", context), do: context

  defp claim(repo, %Signal{producer: :kernel, type: "command.steer"}, job, spec, cap),
    do:
      Lifecycle.claim_continuation_in_tx(repo, job.id, job.agent_uid, job.attempts + 1, spec, cap)

  defp claim(repo, _event, job, spec, cap),
    do: Lifecycle.claim_attempt_in_tx(repo, job.id, job.agent_uid, job.attempts + 1, spec, cap)

  @spec start(Attempt.t()) :: {:ok, term()} | {:error, term()}
  def start(run) do
    with {:ok, :live} <-
           Repo.transact(fn repo ->
             with {:ok, :authorized} <-
                    WorkerRouteAuth.authorize_turn_in_tx(repo, run.job_ref, run.agent_uid, :write),
                  :ok <- Fence.check_in_tx(repo, run, :share),
                  do: {:ok, :live}
           end),
         do:
           WorkerRoute.send_mandatory(
             AgentWorkers.target(run.job_worker),
             TurnEnvelope.turn_start(run.job_ref, run.event, run.spec, run.job_mode, run.context)
           )
  end

  @spec mailbox(Attempt.t()) :: :ok | {:error, term()}
  def mailbox(run) do
    events =
      Repo.transact(fn repo ->
        events =
          Queue.due(run)
          |> Enum.filter(
            &(Signal.produced_by_kernel?(&1) and &1.id != run.signal_id and
                &1.type == "command.steer")
          )

        :ok = WorkAccess.lock_authorizers_in_tx(repo, events)

        with :ok <- Queue.lock_session_in_tx(repo, run.agent_uid, run.session_id),
             :ok <- Fence.check_in_tx(repo, run, :share) do
          events
          |> Enum.reduce_while({:ok, []}, fn event, {:ok, events} ->
            case mailbox_event_in_tx(repo, run, event) do
              {:ok, %Signal{status: live_status} = event}
              when live_status in [:queued, :running] ->
                {:cont, {:ok, [event | events]}}

              {:ok, _closed} ->
                {:cont, {:ok, events}}

              error ->
                {:halt, error}
            end
          end)
        end
      end)

    with {:ok, events} <- events do
      events
      |> Enum.reverse()
      |> Enum.reduce_while(:ok, fn event, :ok ->
        case WorkerRoute.send_mandatory(
               AgentWorkers.target(run.job_worker),
               TurnEnvelope.mailbox_updated(run.job_ref, event)
             ) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp mailbox_event_in_tx(repo, run, snapshot) do
    with %Signal{status: live_status} = event
         when live_status in [:queued, :running] <-
           Ankole.Signals.lock_signal_in_tx(repo, snapshot.id),
         true <- event.agent_uid == run.agent_uid and event.session_id == run.session_id,
         true <- WorkAccess.fields(event) == WorkAccess.fields(snapshot),
         {:ok, %Signal{status: live_status} = authorized}
         when live_status in [:queued, :running] <-
           Ankole.Sessions.Admission.authorize_event_in_tx(repo, event) do
      authorized
      |> Ankole.Ash.update(:start_attempt, %{last_attempt_at: DateTime.utc_now(:microsecond)})
    else
      {:error, _} = error -> error
      {:ok, closed} -> {:ok, closed}
      _closed -> {:ok, nil}
    end
  end

  @spec observe(Attempt.t()) :: {:ok, :running | :finished | {:adopt, map()}} | {:error, term()}
  def observe(run) do
    Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(run.job.id)

    case BackgroundAgentJobs.get_job_for_agent(run.job.id, run.agent_uid) do
      %Job{status: :running, attempts: attempt} when attempt == run.job_ref.attempt ->
        case AgentWorkers.connected_worker(run.agent_uid) do
          {:ok, worker}
          when worker.transport_route != run.job_worker.transport_route or
                 worker.incarnation_id != run.job_worker.incarnation_id ->
            {:ok, {:adopt, worker}}

          _same_or_unavailable ->
            {:ok, :running}
        end

      %Job{} ->
        {:ok, :finished}

      nil ->
        {:error, :job_not_found}
    end
  end

  @spec abort(JobTurnRef.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def abort(ref, worker_id, error) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with {:ok, :authorized} <-
             WorkerRouteAuth.authorize_turn_in_tx(repo, ref, worker_id, :terminal, lock: true),
           %Job{} = job <- repo.get(Job, ref.job_id),
           _turns <- Ankole.BackgroundAgentJobs.Turns.lock_attempt_in_tx(repo, job),
           :ok <- Lifecycle.lock_job_sessions_in_tx(repo, job),
           %Signal{} = event <- Ankole.Signals.lock_signal_in_tx(repo, ref.signal_id) do
        if job.status != :running do
          {:ok, %{signal: event, compensation: nil}}
        else
          error = BackgroundAgentJobs.quota_terminal_error(error, event.agent_uid)

          delay = BackgroundAgentJobs.turn_error_retry_at(error, ref.attempt, now)

          event_result =
            if TurnErrorClassifier.retryable?(error),
              do: Ankole.Ash.update(event, :defer, %{available_at: delay}),
              else: Queue.mark_event_dead_letter_in_tx(repo, event, now, error)

          with {:ok, event} <- event_result,
               {:ok, _compensation} <-
                 Ankole.BackgroundAgentJobs.TurnWatchdog.compensate_in_tx(repo, event, error, now),
               :ok <-
                 Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
                   repo,
                   %{agent_uid: event.agent_uid, session_id: event.session_id},
                   delay
                 ),
               do: {:ok, event}
        end
      end
    end)
  end

  defp admission_result(
         {:error, {:background_agent_job_turn_failures_exhausted, _}},
         event,
         job,
         now
       ),
       do: admission_result({:error, :background_agent_job_attempts_exhausted}, event, job, now)

  defp admission_result({:ok, %{status: :waiting_for_worker} = waiting}, _event, job, _now) do
    AgentWorkers.request(job.agent_uid)
    {:ok, waiting}
  end

  defp admission_result({:error, :agent_worker_ready_timeout}, event, %Job{} = job, now) do
    WorkerWait.resolve_timeout(event, job, now)
  end

  defp admission_result({:error, reason}, event, job, _now)
       when reason in [
              :background_agent_job_attempts_exhausted,
              :background_agent_job_claims_exhausted
            ] do
    code =
      if reason == :background_agent_job_claims_exhausted,
        do: "infrastructure_retries_exhausted",
        else: "attempts_exhausted"

    with {:ok, _} <-
           BackgroundAgentJobs.commit_status_with_wakeup(
             job.id,
             job.agent_uid,
             %{
               "status" => :failed,
               "error" => %{"code" => code, "summary" => "Job retry budget is exhausted."}
             },
             external_completion: true,
             transition_action: :fail_admission
           ),
         {:ok, event} <- BackgroundAgentJobs.complete_signal(event),
         do: {:ok, %{status: :exhausted, signal: event}}
  end

  defp admission_result({:error, {:model_profile_unavailable, profile, reason}}, event, job, _now) do
    with {:ok, _} <-
           BackgroundAgentJobs.commit_status_with_wakeup(
             job.id,
             job.agent_uid,
             %{
               "status" => :failed,
               "error" => %{
                 "code" => "model_profile_unavailable",
                 "summary" => "Model profile #{profile} is unavailable: #{inspect(reason)}"
               }
             },
             external_completion: true,
             transition_action: :fail_admission
           ),
         {:ok, event} <- BackgroundAgentJobs.complete_signal(event),
         do: {:ok, %{status: :failed, signal: event}}
  end

  defp admission_result({:error, {:input_not_due, event}}, _snapshot, _job, _now),
    do: {:ok, %{status: :deferred, signal: event, retry_at: event.available_at}}

  defp admission_result({:error, :input_unavailable} = result, _event, _job, _now), do: result

  defp admission_result(
         {:error, reason},
         %Signal{producer: :kernel, type: type} = event,
         _job,
         now
       )
       when type == "command.steer" and
              reason in [:human_access_revoked, :work_authorization_review_required] do
    Repo.transact(fn repo ->
      with {:ok, event} <-
             Queue.mark_event_dead_letter_in_tx(
               repo,
               event,
               now,
               %{"code" => Atom.to_string(reason)}
             ),
           do: {:ok, %{status: :dead_letter, signal: event}}
    end)
  end

  defp admission_result({:error, reason}, event, job, now) do
    code = if is_atom(reason), do: Atom.to_string(reason), else: "job_admission_rejected"

    Repo.transact(fn repo ->
      with {:ok, compensation} <- fail_unadmitted_job(repo, job, code, now),
           {:ok, event} <-
             Queue.mark_event_dead_letter_in_tx(repo, event, now, %{
               "code" => code,
               "reason" => inspect(reason)
             }) do
        {:ok,
         %{
           status: :dead_letter,
           signal: event,
           wakeup_event: (compensation || %{})[:wakeup_event]
         }}
      end
    end)
  end

  defp admission_result(result, _event, _job, _now), do: result

  defp fail_unadmitted_job(_repo, nil, _code, _now), do: {:ok, nil}

  defp fail_unadmitted_job(repo, job, code, now),
    do:
      Lifecycle.commit_status_with_wakeup_in_tx(
        repo,
        job.id,
        job.agent_uid,
        %{
          "status" => :failed,
          "error" => %{"code" => code, "summary" => "Job admission was rejected."}
        },
        now,
        nil,
        nil,
        nil,
        external_completion: true,
        transition_action: :fail_admission
      )

  @spec opts(Signal.t(), Job.t(), keyword()) :: keyword()
  def opts(%Signal{}, %Job{} = job, opts) do
    opts =
      Keyword.merge(opts,
        profile: job.model_profile
      )

    case job.runtime_projection do
      %{} = projection when map_size(projection) > 0 ->
        Keyword.put(
          opts,
          :turn_start_overrides,
          RuntimeProjection.turn_start_overrides(projection)
        )

      _missing ->
        opts
    end
  end
end
