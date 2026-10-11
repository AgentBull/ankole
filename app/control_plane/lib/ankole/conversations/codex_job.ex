defmodule Ankole.Conversations.CodexJob do
  @moduledoc "Admits or adopts a durable Job attempt. A Driver never owns the Codex execution."
  import Ecto.Query
  alias Ankole.{BackgroundAgentJobs, Repo}
  alias Ankole.BackgroundAgentJobs.{Lifecycle, RuntimeProjection, Schemas.Job}
  alias Ankole.Conversations.{Context, Fence, JobTurnRef, Run}
  alias Ankole.Principals.WorkAccess
  alias Ankole.SignalsGateway.{ActorEvent, Actors}

  alias Ankole.SignalsGateway.ActorRuntime.{
    AgentWorkers,
    BackgroundAgentJobCap,
    SessionWorkspaces,
    TurnEnvelope,
    TurnErrorClassifier,
    TurnRuntimeEnv,
    WorkerRoute,
    WorkerRouteAuth
  }

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace

  @spec admit(map(), ActorEvent.t(), keyword()) :: {:ok, Run.t() | map()} | {:error, term()}
  def admit(key, event, opts) do
    with {:ok, id} <- BackgroundAgentJobs.parse_job_session_id(key.session_id),
         %Job{} = snapshot <- BackgroundAgentJobs.get_job_for_agent(id, key.agent_uid) do
      prepared = Context.runtime(key, __MODULE__.opts(event, snapshot, opts))

      context =
        if snapshot.status == "running",
          do: {:ok, nil},
          else: Context.resolve(key.agent_uid, key.session_id)

      cap = BackgroundAgentJobCap.max_running_per_agent()

      result =
        Repo.transact(fn repo ->
          # Keep the same lock order as Job RPC and status commit.
          worker = AgentWorkers.lock_in_tx(repo, key.agent_uid)

          with :ok <- Lifecycle.lock_agent_slots(repo, key.agent_uid),
               %Job{} = job <-
                 repo.one(
                   from j in Job,
                     where: j.id == ^id and j.agent_uid == ^key.agent_uid,
                     lock: "FOR UPDATE"
                 ),
               :ok <- admission_access(repo, event, job) do
            admit_locked_in_tx(repo, key, event, job, worker, prepared, context, cap)
          else
            nil -> {:error, :job_not_found}
            error -> error
          end
        end)

      admission_result(result, event, snapshot)
    else
      nil -> admission_result({:error, :job_not_found}, event, nil)
      error -> admission_result(error, event, nil)
    end
  end

  defp admit_locked_in_tx(repo, key, event, job, worker, prepared, context, cap) do
    cond do
      job.status in Job.terminal_statuses() ->
        with {:ok, event} <-
               Actors.mark_event_completed_in_tx(
                 repo,
                 event,
                 DateTime.utc_now(:microsecond)
               ),
             do: {:ok, %{status: :idle, actor_event: event}}

      match?({:error, _}, prepared) ->
        prepared

      is_nil(worker) or worker.state not in ["ready", "draining"] ->
        {:error, :agent_worker_unavailable}

      true ->
        {:ok, spec} = prepared
        admit_attempt_in_tx(repo, key, event, job, worker, spec, context, cap)
    end
  end

  defp admission_access(_repo, %{last_attempt_at: %DateTime{}}, %{status: "running"}), do: :ok

  defp admission_access(repo, event, job) do
    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
         :ok <- WorkAccess.check_in_tx(repo, event),
         do: WorkAccess.check_in_tx(repo, job)
  end

  defp admit_attempt_in_tx(repo, key, snapshot, job, worker, spec, context, cap) do
    mode = if job.status == "running", do: "adopt", else: "start"

    with {:ok, agent_context} <- start_context(mode, context),
         {:ok, worker} <- reserve(repo, worker, mode),
         {:ok, job} <-
           if(mode == "adopt",
             do: {:ok, job},
             else: claim(repo, snapshot, job, spec, cap)
           ),
         {:ok, agent_context} <- project_context(mode, agent_context, job),
         {:ok, _} <- SessionWorkspaces.ensure_in_tx(repo, key.agent_uid, key.session_id),
         %ActorSessionWorkspace{} = workspace <-
           repo.one(
             from w in ActorSessionWorkspace,
               where: w.agent_uid == ^key.agent_uid and w.session_id == ^key.session_id,
               lock: "FOR UPDATE"
           ),
         %ActorEvent{input_state: "open", completed_at: nil} = event <-
           Actors.lock_actor_event_in_tx(repo, snapshot.id),
         {:ok, event} <-
           repo.update(
             ActorEvent.changeset(event, %{last_attempt_at: DateTime.utc_now(:microsecond)})
           ),
         {:ok, workspace} <-
           repo.update(Ecto.Changeset.change(workspace, epoch: workspace.epoch + 1)),
         {:ok, spec} <-
           Ankole.BackgroundAgentJobs.RuntimeProjection.turn_start_overrides(
             job.runtime_projection
           ) do
      # A running attempt's trigger precedes every unapplied steer. It stays open
      # until its terminal status commit, so adoption uses the same identity.
      ref = %JobTurnRef{
        agent_uid: key.agent_uid,
        session_id: key.session_id,
        actor_event_id: event.id,
        job_id: job.id,
        attempt: job.attempts
      }

      {:ok,
       %Run{
         agent_uid: key.agent_uid,
         session_id: key.session_id,
         actor_event_id: event.id,
         epoch: workspace.epoch,
         event: event,
         delivered_event: event,
         kind: :job,
         context: agent_context,
         workspace_id: workspace.id,
         spec:
           Map.merge(spec, %{
             workspace_id: workspace.id,
             runtime_env: TurnRuntimeEnv.resolve(event)
           }),
         job: job,
         job_ref: ref,
         job_worker: worker,
         job_mode: mode
       }}
    else
      nil -> {:error, :input_unavailable}
      %ActorEvent{} -> {:error, :input_unavailable}
      {:error, _} = error -> error
    end
  end

  defp project_context("adopt", _context, _job), do: {:ok, nil}
  defp project_context("start", context, job), do: Context.job(context, job)

  defp start_context("adopt", _context), do: {:ok, nil}
  defp start_context("start", {:ok, nil}), do: {:error, :input_unavailable}
  defp start_context("start", context), do: context

  defp claim(repo, %{type: "command.steer"}, job, spec, cap),
    do:
      Lifecycle.claim_continuation_in_tx(repo, job.id, job.agent_uid, job.attempts + 1, spec, cap)

  defp claim(repo, _event, job, spec, cap),
    do: Lifecycle.claim_attempt_in_tx(repo, job.id, job.agent_uid, job.attempts + 1, spec, cap)

  defp reserve(_repo, worker, "adopt"), do: {:ok, worker}
  defp reserve(repo, worker, "start"), do: AgentWorkers.reserve_slot_in_tx(repo, worker.agent_uid)

  @spec start(Run.t()) :: {:ok, term()} | {:error, term()}
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

  @spec mailbox(Run.t()) :: :ok | {:error, term()}
  def mailbox(run) do
    events =
      Repo.transact(fn repo ->
        with :ok <- Fence.check_in_tx(repo, run, :share) do
          Run.open_events(run)
          |> Enum.filter(&(&1.id != run.actor_event_id and &1.type == "command.steer"))
          |> Enum.reduce_while({:ok, []}, fn event, {:ok, events} ->
            with {:ok, %ActorEvent{input_state: "open", completed_at: nil} = event} <-
                   Ankole.Conversations.Admission.authorize_event_in_tx(repo, event),
                 {:ok, event} <-
                   repo.update(
                     ActorEvent.changeset(event, %{
                       last_attempt_at: DateTime.utc_now(:microsecond)
                     })
                   ) do
              {:cont, {:ok, [event | events]}}
            else
              {:ok, _closed} -> {:cont, {:ok, events}}
              error -> {:halt, error}
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

  @spec observe(Run.t()) :: {:ok, :running | :finished | {:adopt, map()}} | {:error, term()}
  def observe(run) do
    Ankole.BackgroundAgentJobs.TurnWatchdog.reconcile_stuck_job(run.job.id)

    case BackgroundAgentJobs.get_job_for_agent(run.job.id, run.agent_uid) do
      %Job{status: "running", attempts: attempt} when attempt == run.job_ref.attempt ->
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
           %ActorEvent{} = event <- Actors.lock_actor_event_in_tx(repo, ref.actor_event_id),
           %Job{} = job <- repo.get(Job, ref.job_id) do
        if job.status != "running" do
          {:ok, %{actor_event: event, compensation: nil}}
        else
          error = BackgroundAgentJobs.quota_terminal_error(error, event.agent_uid)

          event_result =
            if TurnErrorClassifier.retryable?(error),
              do: {:ok, event},
              else: Actors.mark_event_dead_letter_in_tx(repo, event, now, error)

          compensate =
            if error["code"] == Ankole.BackgroundAgentJobs.TurnWatchdog.stall_code() and
                 event.input_state == "open",
               do: &Ankole.BackgroundAgentJobs.TurnWatchdog.compensate_in_tx/4,
               else: &BackgroundAgentJobs.compensate_turn_error_in_tx/4

          with {:ok, event} <- event_result,
               {:ok, compensation} <- compensate.(repo, event, error, now),
               delay = BackgroundAgentJobs.turn_error_retry_at(error, ref.attempt, now),
               {:ok, event} <- repo.update(ActorEvent.changeset(event, %{available_at: delay})),
               :ok <-
                 Ankole.Conversations.Jobs.EnsureDriver.enqueue_in_tx(
                   repo,
                   %{agent_uid: event.agent_uid, session_id: event.session_id},
                   delay
                 ) do
            {:ok, %{actor_event: event, compensation: compensation}}
          end
        end
      end
    end)
    |> Ankole.Conversations.deliver_committed(fn value ->
      [
        value.actor_event,
        (value.compensation || %{})[:wakeup_event],
        (value.compensation || %{})[:dispatch_event]
      ]
    end)
    |> case do
      {:ok, %{actor_event: event}} -> {:ok, event}
      error -> error
    end
  end

  defp admission_result({:error, {:background_agent_job_turn_failures_exhausted, _}}, event, job),
    do: admission_result({:error, :background_agent_job_attempts_exhausted}, event, job)

  defp admission_result({:error, reason}, event, job)
       when reason in [
              :agent_worker_unavailable,
              :no_worker_capacity,
              :background_agent_job_agent_at_capacity
            ] do
    AgentWorkers.request(job.agent_uid)

    with {:ok, event} <-
           BackgroundAgentJobs.defer_actor_event(
             event,
             DateTime.add(DateTime.utc_now(:microsecond), 30)
           ),
         do: {:ok, %{status: :waiting_for_worker, actor_event: event}}
  end

  defp admission_result({:error, reason}, event, job)
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
               "status" => "failed",
               "error" => %{"code" => code, "summary" => "Job retry budget is exhausted."}
             },
             external_completion: true
           ),
         {:ok, event} <- BackgroundAgentJobs.complete_actor_event(event),
         do: {:ok, %{status: :exhausted, actor_event: event}}
  end

  defp admission_result({:error, {:model_profile_unavailable, profile, reason}}, event, job) do
    with {:ok, _} <-
           BackgroundAgentJobs.commit_status_with_wakeup(
             job.id,
             job.agent_uid,
             %{
               "status" => "failed",
               "error" => %{
                 "code" => "model_profile_unavailable",
                 "summary" => "Model profile #{profile} is unavailable: #{inspect(reason)}"
               }
             },
             external_completion: true
           ),
         {:ok, event} <- BackgroundAgentJobs.complete_actor_event(event),
         do: {:ok, %{status: :failed, actor_event: event}}
  end

  defp admission_result({:error, :input_unavailable} = result, _event, _job), do: result

  defp admission_result({:error, reason}, %{type: type} = event, _job)
       when type == "command.steer" and
              reason in [:human_access_revoked, :work_authorization_review_required] do
    Repo.transact(fn repo ->
      with {:ok, event} <-
             Actors.mark_event_dead_letter_in_tx(
               repo,
               event,
               DateTime.utc_now(:microsecond),
               %{"code" => Atom.to_string(reason)}
             ),
           do: {:ok, %{status: :dead_letter, actor_event: event}}
    end)
  end

  defp admission_result({:error, reason}, event, job) do
    now = DateTime.utc_now(:microsecond)
    code = if is_atom(reason), do: Atom.to_string(reason), else: "job_admission_rejected"

    Repo.transact(fn repo ->
      with {:ok, compensation} <- fail_unadmitted_job(repo, job, code, now),
           {:ok, event} <-
             Actors.mark_event_dead_letter_in_tx(repo, event, now, %{
               "code" => code,
               "reason" => inspect(reason)
             }) do
        {:ok,
         %{
           status: :dead_letter,
           actor_event: event,
           wakeup_event: (compensation || %{})[:wakeup_event]
         }}
      end
    end)
    |> Ankole.Conversations.deliver_committed(&[&1.wakeup_event])
  end

  defp admission_result(result, _event, _job), do: result

  defp fail_unadmitted_job(_repo, nil, _code, _now), do: {:ok, nil}

  defp fail_unadmitted_job(repo, job, code, now),
    do:
      Lifecycle.commit_status_with_wakeup_in_tx(
        repo,
        job.id,
        job.agent_uid,
        %{
          "status" => "failed",
          "error" => %{"code" => code, "summary" => "Job admission was rejected."}
        },
        now,
        nil,
        nil,
        nil,
        external_completion: true
      )

  @spec opts(ActorEvent.t(), Job.t(), keyword()) :: keyword()
  def opts(%ActorEvent{}, %Job{} = job, opts) do
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
