defmodule Ankole.BackgroundAgentJobs.Lifecycle do
  @moduledoc false

  require Ankole.ModelIntegerID

  import Ecto.Query

  alias Ankole.Signals.Signal
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.AgentWorkers.WorkerRouteAuth
  alias Ankole.AgentWorkers
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Dispatch
  alias Ankole.BackgroundAgentJobs.JobState
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.BackgroundAgentJobs.Wakeups
  alias Ankole.BackgroundAgentJobs.WorkerWait

  @max_execution_attempts 5
  @max_claims 25
  @max_consecutive_turn_failures 5

  @doc false
  @spec upsert_turn_from_worker(pos_integer(), String.t(), map(), JobTurnRef.t(), String.t()) ::
          {:ok, Turn.t()} | {:error, term()}
  def upsert_turn_from_worker(job_id, agent_uid, attrs, %JobTurnRef{} = turn_ref, worker_id)
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) and is_map(attrs) and
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
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) and expected_attempt > 0 and
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
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) and expected_attempt > 0 and
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
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{attempts: attempts} = job when attempts > 0 <-
           Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
         {:ok, :queued} <- JobState.transition(:requeue, job.status, :queued) do
      Ankole.Ash.update(job, :requeue, %{})
    else
      nil ->
        {:error, :job_not_found}

      %Job{} ->
        {:error, :background_agent_job_attempt_changed}

      {:error, {:invalid_status_transition, _current, _next}} ->
        {:error, :background_agent_job_attempt_changed}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec requeue_retryable_attempt_in_tx(module(), pos_integer(), String.t(), keyword()) ::
          {:ok, Job.t() | nil} | {:error, term()}
  def requeue_retryable_attempt_in_tx(repo, job_id, agent_uid, opts \\ [])
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) do
    charge? = Keyword.get(opts, :charge, false)

    with :ok <- lock_agent_slots(repo, agent_uid) do
      case Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
        %Job{} = job ->
          case JobState.transition(:requeue, job.status, :queued) do
            {:ok, :queued} ->
              Ankole.Ash.update(job, :requeue, %{
                execution_failures: job.execution_failures + if(charge?, do: 1, else: 0)
              })

            # A Job that already left `running` (stopped, completed, waiting, or
            # already requeued) needs no compensation; the abort stays a no-op.
            {:error, {:invalid_status_transition, _current, _next}} ->
              {:ok, nil}
          end

        nil ->
          {:ok, nil}
      end
    end
  end

  @spec commit_status_with_wakeup(pos_integer(), String.t(), map(), keyword()) ::
          {:ok, %{job: Job.t(), wakeup_event: Signal.t() | nil}}
          | {:error, term()}
  def commit_status_with_wakeup(job_id, agent_uid, attrs, opts \\ [])
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) and is_map(attrs) and
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
            Keyword.take(opts, [:external_completion, :applied_signal_ids, :transition_action])
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
    with :ok <- lock_successor_owner_prefix_in_tx(repo, job_id, agent_uid, attrs, opts),
         :ok <- lock_runtime_prefix_in_tx(repo, agent_uid, turn_ref, worker_id),
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
          map() | nil,
          keyword()
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
    normalized_attrs = attrs |> Attrs.normalize() |> normalize_status_attr()

    with :ok <- lock_agent_slots(repo, agent_uid),
         %Job{} = job <- Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
         :ok <- authorize_successor_owner_in_tx(repo, job, normalized_attrs, turn_ref, opts) do
      cond do
        match?(%JobTurnRef{}, turn_ref) and job.status != :running ->
          if job.attempts == turn_ref.attempt and job.status == normalized_attrs["status"],
            do: {:ok, %{job: job, wakeup_event: nil}},
            else: {:error, :background_agent_job_attempt_changed}

        is_nil(turn_ref) and job.status in JobState.terminal_statuses() and
            job.status == normalized_attrs["status"] ->
          {:ok, %{job: job, wakeup_event: nil}}

        true ->
          commit_running_status_in_tx(
            repo,
            job,
            normalized_attrs,
            now,
            turn_ref,
            turn_interruption,
            opts
          )
      end
    else
      nil -> {:error, :job_not_found}
      error -> error
    end
  end

  defp commit_running_status_in_tx(repo, job, attrs, now, turn_ref, turn_interruption, opts) do
    transition_action =
      Keyword.get_lazy(opts, :transition_action, fn ->
        if Keyword.get(opts, :external_completion, false),
          do: :external_complete,
          else: :worker_report
      end)

    with attrs <- Wakeups.bound_result_path_handoffs(attrs),
         :ok <- enforce_status_transition(job, attrs, transition_action),
         :ok <-
           maybe_interrupt_active_slots(
             repo,
             job,
             turn_interruption || terminal_turn_interruption(attrs),
             now
           ),
         :ok <- enforce_turn_trajectory_completion(repo, job, attrs, opts),
         {:ok, job} <-
           Ankole.Ash.update(
             job,
             transition_action,
             attrs
             |> WorkerWait.clear()
             |> preserve_metadata(job)
             |> lifecycle_timestamps(job, now)
             |> transition_input(transition_action)
           ),
         {:ok, successor_id} <- reserve_successor_in_tx(repo, job, turn_ref, opts),
         :ok <- lock_job_sessions_in_tx(repo, job, successor_id),
         {:ok, job} <- complete_applied_in_tx(repo, job, turn_ref, opts, now),
         {:ok, steer_outcome} <-
           resolve_open_steers_after_commit(
             repo,
             job,
             now,
             turn_ref,
             Keyword.put(opts, :successor_id, successor_id)
           ),
         {:ok, wakeup_event} <- Wakeups.conclude_transition_in_tx(repo, job, now, steer_outcome) do
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
         %Job{status: :succeeded} = job,
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
                 Dispatch.seed_steer_successor_in_tx(
                   repo,
                   job,
                   steers,
                   now,
                   Keyword.fetch!(opts, :successor_id)
                 ),
               :ok <- complete_steer_events_in_tx(repo, steers, now) do
            {:ok, %{successor_job_id: successor.id, dispatch_event: dispatch_event}}
          end
        end
    end
  end

  defp resolve_open_steers_after_commit(repo, %Job{status: status} = job, now, _turn_ref, _opts)
       when status in [:failed, :stopped] do
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
       when job.status in [:waiting_on_user, :succeeded, :failed, :stopped] do
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
          from(event in Signal,
            where:
              event.id in ^ids and event.agent_uid == ^job.agent_uid and
                event.session_id == ^Ankole.BackgroundAgentJobs.job_session_id(job.id)
          )
        )

      record_applied_source_in_tx(repo, job, events)
    else
      {:ok, job}
    end
  end

  defp record_applied_source_in_tx(_repo, job, events) do
    case Ankole.Conversations.Route.applied_human_source(job, events) do
      nil ->
        {:ok, job}

      id ->
        Ankole.Ash.update(job, :record_applied_signal, %{signal_id: id})
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

  # An external completion or admission failure is an accountable override of
  # the worker deliverable contract: the caller has verified the outcome outside
  # the runtime, so no completed lead Turn is required.
  defp enforce_turn_trajectory_completion(repo, %Job{} = job, attrs, opts) do
    if Keyword.get(opts, :external_completion, false) or
         Keyword.get(opts, :transition_action) == :fail_admission do
      :ok
    else
      do_enforce_turn_trajectory_completion(repo, job, attrs)
    end
  end

  defp do_enforce_turn_trajectory_completion(
         repo,
         %Job{} = job,
         %{"status" => status}
       )
       when status in [:waiting_on_user, :succeeded],
       do:
         Turns.ensure_lead_closed_for_current_attempt_in_tx(repo, job,
           require_turn: true,
           latest_status: if(status == :waiting_on_user, do: :interrupted, else: :completed),
           latest_error_code: if(status == :waiting_on_user, do: "request_user_input"),
           require_pending_tool_call: if(status == :waiting_on_user, do: "request_user_input")
         )

  defp do_enforce_turn_trajectory_completion(
         repo,
         %Job{attempts: attempts} = job,
         %{"status" => status}
       )
       when attempts > 0 and status in [:failed, :stopped],
       do: Turns.ensure_lead_closed_for_current_attempt_in_tx(repo, job)

  defp do_enforce_turn_trajectory_completion(_repo, %Job{}, _attrs), do: :ok

  defp terminal_turn_interruption(%{"status" => :succeeded}) do
    %{
      "code" => "background_agent_job_succeeded",
      "summary" => "The Job completed before this runtime Turn reported completion."
    }
  end

  defp terminal_turn_interruption(%{"status" => :failed} = attrs) do
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

  defp terminal_turn_interruption(%{"status" => :stopped}) do
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

  defp claim_attempt(repo, %Job{} = job, expected_attempt, turn_start_spec, max_running) do
    cond do
      job.status in JobState.terminal_statuses() ->
        {:error, {:background_agent_job_terminal, job}}

      job.execution_failures >= @max_execution_attempts ->
        {:error, :background_agent_job_attempts_exhausted}

      job.attempts >= @max_claims ->
        {:error, :background_agent_job_claims_exhausted}

      job.attempts + 1 != expected_attempt ->
        {:error, :background_agent_job_attempt_changed}

      true ->
        start_attempt(repo, job, expected_attempt, turn_start_spec, max_running, :claim_attempt)
    end
  end

  # Continuations enforce @max_claims and consecutive Turn failure budgets so
  # user steers can continue a live Job while repeated Turn failures stop.
  defp claim_continuation(repo, %Job{} = job, expected_attempt, turn_start_spec, max_running) do
    cond do
      job.status in JobState.terminal_statuses() ->
        {:error, {:background_agent_job_terminal, job}}

      job.attempts >= @max_claims ->
        {:error, :background_agent_job_claims_exhausted}

      job.attempts + 1 != expected_attempt ->
        {:error, :background_agent_job_attempt_changed}

      true ->
        case Turns.consecutive_lead_failures_in_tx(repo, job, @max_consecutive_turn_failures) do
          {count, error} when count >= @max_consecutive_turn_failures ->
            {:error, {:background_agent_job_turn_failures_exhausted, error}}

          _below_limit ->
            start_attempt(
              repo,
              job,
              expected_attempt,
              turn_start_spec,
              max_running,
              :claim_continuation
            )
        end
    end
  end

  defp start_attempt(
         repo,
         %Job{} = job,
         expected_attempt,
         turn_start_spec,
         max_running,
         transition_action
       ) do
    case JobState.transition(transition_action, job.status, :running) do
      {:error, {:invalid_status_transition, current, next}} ->
        {:error, {:invalid_background_agent_job_status_transition, current, next}}

      {:ok, :running} ->
        if not capacity_available_in_tx?(repo, job, max_running) do
          {:error, :background_agent_job_agent_at_capacity}
        else
          now = now()

          with :ok <- Turns.interrupt_before_attempt_in_tx(repo, job, expected_attempt, now),
               {:ok, runtime_projection} <-
                 ensure_runtime_projection(job, turn_start_spec) do
            Ankole.Ash.update(
              job,
              transition_action,
              WorkerWait.clear(%{
                attempts: expected_attempt,
                started_at: job.started_at || now,
                completed_at: nil,
                metadata: Map.delete(job.metadata || %{}, "pending_user_input"),
                runtime_projection: runtime_projection
              })
            )
          end
        end
    end
  end

  defp ensure_runtime_projection(%Job{runtime_projection: %{} = projection}, %{}),
    do: {:ok, projection}

  defp ensure_runtime_projection(%Job{} = job, %{} = turn_start_spec),
    do: RuntimeProjection.capture(job.agent_uid, turn_start_spec)

  defp transition_input(attrs, :worker_report) do
    {status, attrs} = Map.pop!(attrs, "status")
    Map.put(attrs, "next_status", status)
  end

  defp transition_input(attrs, _action), do: Map.delete(attrs, "status")

  def lock_agent_slots(repo, agent_uid),
    do: Ankole.AgentWorkers.SlotLock.lock(repo, :background_agent_jobs, agent_uid)

  @doc "Checks work capacity while the caller holds the Agent slot lock."
  def capacity_available_in_tx?(repo, %Job{} = job, max_running) do
    job.status in JobState.running_statuses() or
      running_count(repo, job.agent_uid, job.id) < max_running
  end

  defp normalize_status_attr(%{"status" => status} = attrs) do
    case JobState.cast_status(status) do
      {:ok, cast} -> Map.put(attrs, "status", cast)
      :error -> attrs
    end
  end

  defp normalize_status_attr(attrs), do: attrs

  defp enforce_status_transition(%Job{status: current}, attrs, transition_action) do
    next = Map.get(attrs, "status")
    terminal_statuses = JobState.terminal_statuses()

    cond do
      is_nil(next) ->
        {:error, :background_agent_job_status_missing}

      next in terminal_statuses and current in terminal_statuses and next != current ->
        {:error, :background_agent_job_terminal}

      is_atom(next) ->
        case JobState.transition(transition_action, current, next) do
          {:ok, ^next} ->
            :ok

          {:error, {:invalid_status_transition, ^current, ^next}} ->
            {:error, {:invalid_background_agent_job_status_transition, current, next}}
        end

      true ->
        {:error, {:invalid_background_agent_job_status_transition, current, next}}
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
          job.agent_uid == ^agent_uid and job.status in ^JobState.running_statuses() and
            job.id != ^job_id
      ),
      :count
    )
  end

  defp lifecycle_timestamps(attrs, job, now) do
    status = Map.get(attrs, "status")

    cond do
      status in JobState.running_statuses() ->
        Map.put_new(attrs, "started_at", job.started_at || now)

      status in JobState.terminal_statuses() ->
        attrs
        |> Map.put_new("started_at", job.started_at || now)
        |> Map.put_new("completed_at", now)

      true ->
        attrs
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)

  @doc false
  def lock_job_sessions_in_tx(repo, job, successor_id \\ nil) do
    sessions = [
      {job.agent_uid, Ankole.BackgroundAgentJobs.job_session_id(job.id)},
      {job.agent_uid, job.owner_session_id}
    ]

    sessions =
      if successor_id,
        do: [{job.agent_uid, Ankole.BackgroundAgentJobs.job_session_id(successor_id)} | sessions],
        else: sessions

    Ankole.Sessions.Queue.lock_sessions_in_tx(repo, sessions)
  end

  defp lock_successor_owner_prefix_in_tx(repo, job_id, agent_uid, attrs, opts) do
    attrs = attrs |> Attrs.normalize() |> normalize_status_attr()

    if needs_successor_owner?(attrs, opts) do
      AgentWorkers.lock_in_tx(repo, agent_uid)
      :ok = lock_agent_slots(repo, agent_uid)

      case Queries.get_for_agent(repo, job_id, agent_uid, []) do
        %Job{owner_session_id: session_id} ->
          case Ankole.Workflow.Queries.parse_task_session_id(session_id) do
            {:ok, _call_id} -> Ankole.Workflow.Slot.lock_agent_slots(repo, agent_uid)
            :error -> :ok
          end

        nil ->
          :ok
      end
    else
      :ok
    end
  end

  defp authorize_successor_owner_in_tx(repo, job, attrs, turn_ref, opts) do
    if needs_successor_owner?(attrs, opts) and job.status == :running do
      applied = Keyword.get(opts, :applied_signal_ids, [])
      applied = if turn_ref, do: [turn_ref.signal_id | applied], else: applied
      Dispatch.authorize_steer_successor_in_tx(repo, job, Enum.uniq(applied))
    else
      :ok
    end
  end

  defp needs_successor_owner?(%{"status" => :succeeded}, opts),
    do: not Keyword.get(opts, :external_completion, false)

  defp needs_successor_owner?(_attrs, _opts), do: false

  defp reserve_successor_in_tx(repo, %Job{status: :succeeded} = job, turn_ref, opts) do
    if Keyword.get(opts, :external_completion, false) do
      {:ok, nil}
    else
      applied = Keyword.get(opts, :applied_signal_ids, [])
      applied = if turn_ref, do: [turn_ref.signal_id | applied], else: applied
      Dispatch.reserve_steer_successor_id_in_tx(repo, job, Enum.uniq(applied))
    end
  end

  defp reserve_successor_in_tx(_repo, _job, _turn_ref, _opts), do: {:ok, nil}

  def stop_human_work_in_tx(repo, uid, version, now) do
    allowed_from =
      Enum.filter(
        JobState.statuses(),
        &JobState.transition_allowed?(:stop_human_work, &1, :stopped)
      )

    query =
      from(job in Job,
        where:
          job.human_uid == ^uid and job.human_access_version < ^version and
            job.status in ^allowed_from
      )

    ids = repo.all(from(job in query, select: job.id))

    jobs =
      repo.all(from(job in query, where: job.id in ^ids, order_by: job.id, lock: "FOR UPDATE"),
        lock_identity: {"background_agent_jobs", ids}
      )

    Enum.each(jobs, fn job ->
      {:ok, _} =
        Repo.with_tenant(job.tenant_id, fn ->
          Ankole.Ash.update(
            job,
            :stop_human_work,
            WorkerWait.clear(%{
              completed_at: now,
              error: %{"code" => "human_access_revoked"}
            })
          )
        end)
    end)

    {length(jobs), nil}
  end
end
