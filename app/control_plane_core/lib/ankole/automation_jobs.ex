defmodule Ankole.AutomationJobs do
  @moduledoc """
  Owns automation job definitions, durable runs, and emitted Agent events.

  Trigger domains keep their own claim and recurrence rules. They call
  `enqueue_run_in_tx/5` inside that existing transaction when a trigger names
  an automation job.

  Each write operation is a generic action that owns its transaction and must
  be the top-level call. It gives `{:ok, value}` or `{:error, reason}`.
  """

  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  require Ash.Query
  require Ankole.ModelIntegerID
  @behaviour Ankole.Sessions.AsyncWorkUnit

  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.AgentWorkers
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Repo
  alias Ankole.Conversations.Route
  alias Ankole.Text

  @log_max_bytes 65_536
  @payload_max_bytes 1_048_576
  @finished_run_statuses [:succeeded, :failed, :cancelled]

  @type enqueue_result :: %{
          required(:status) => :queued | :failed,
          required(:automation_job_run) => Run.t(),
          optional(:signal) => Ankole.Signals.Signal.t() | nil
        }

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/automation-jobs", Job do
        index(:console_list, name: "list_automation_jobs", derive_sort?: false)
      end

      base_route "/agents/:agent_uid/automation-jobs", Job do
        get(:read, name: "get_automation_job")
      end

      base_route "/agents/:agent_uid/automation-jobs/:automation_job_id/runs", Run do
        index(:console_list, name: "list_automation_job_runs", derive_sort?: false)
      end
    end
  end

  resources do
    resource Job do
      define(:get_automation_job, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_automation_jobs, action: :read)
      define(:finish_script_import_job, action: :finish_script_import)
      define(:reauthorize_automation_job, action: :reauthorize)
    end

    resource Run do
      define(:get_automation_job_run, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_automation_job_runs, action: :read)
    end
  end

  @doc """
  Counts, in every tenant, the running Runs of the automation jobs that one
  Human authorized with an access version older than `version`.
  """
  @spec count_running_runs_for_human(String.t(), integer()) :: non_neg_integer()
  def count_running_runs_for_human(uid, version) do
    job_ids =
      Job
      |> Ash.Query.for_read(:work_across_tenants)
      |> Ash.Query.filter(human_uid == ^uid and human_access_version < ^version)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read_across_tenants!()
      |> Enum.map(& &1.id)

    Run
    |> Ash.Query.for_read(:across_tenants)
    |> Ash.Query.filter(automation_job_id in ^job_ids and status == :running)
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read_across_tenants!()
    |> length()
  end

  @doc """
  Creates one non-idempotent automation job.

  The script must already be in the Agent's drive: `drive_prefix` names a
  folder that holds `main.ts`.
  """
  @spec create_job(map()) :: {:ok, Job.t()} | {:error, term()}
  def create_job(attrs) when is_map(attrs),
    do: Ankole.Ash.run_action(Job, :create_job, %{attrs: attrs})

  @doc false
  def create_job_in_tx(repo, attrs) do
    attrs = Ankole.Principals.WorkAccess.inherit(repo, normalize_agent_uid(attrs))

    with :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
         changeset = Ankole.Ash.for_create(Job, :create, attrs),
         :ok <- require_script_in_drive(changeset) do
      Ankole.Ash.create(changeset)
    end
  end

  # The check reads the cast fields. An invalid changeset reports its own
  # errors at the insert.
  defp require_script_in_drive(%Ash.Changeset{valid?: false}), do: :ok

  defp require_script_in_drive(changeset) do
    agent_uid = Ash.Changeset.get_attribute(changeset, :agent_uid)
    prefix = Ash.Changeset.get_attribute(changeset, :drive_prefix)

    case Ankole.Files.fetch(agent_uid, prefix <> "/main.ts") do
      {:ok, _file} -> :ok
      {:error, _reason} -> {:error, :automation_job_script_missing}
    end
  end

  @doc """
  Lists recent automation jobs owned by one Agent session, by every session of
  the Agent when `owner_session_id` is `nil`, or across every Agent when
  `agent_uid` is also `nil`.
  """
  @spec list_jobs(String.t() | nil, String.t() | nil, keyword()) :: [Job.t()]
  def list_jobs(agent_uid, owner_session_id, opts \\ [])
      when (is_binary(agent_uid) or is_nil(agent_uid)) and
             (is_binary(owner_session_id) or is_nil(owner_session_id)) do
    limit = opts |> Keyword.get(:limit, 100) |> bounded_limit(500, 100)

    {:ok, jobs} =
      Job
      |> maybe_where_agent(agent_uid)
      |> maybe_where_owner_session(owner_session_id)
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit)
      |> Ankole.Ash.read()

    jobs
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid) do
    agent_uid = String.downcase(agent_uid)
    Ash.Query.filter(query, agent_uid == ^agent_uid)
  end

  @doc """
  Gets one automation job only when the Agent session owns it. A `nil`
  `owner_session_id` accepts any session of the Agent.
  """
  @spec get_job(String.t(), String.t() | nil, pos_integer()) ::
          {:ok, Job.t()} | {:error, :automation_job_not_found}
  def get_job(agent_uid, owner_session_id, job_id)
      when is_binary(agent_uid) and (is_binary(owner_session_id) or is_nil(owner_session_id)) and
             Ankole.ModelIntegerID.valid?(job_id) do
    agent_uid = String.downcase(agent_uid)

    Job
    |> Ash.Query.filter(id == ^job_id and agent_uid == ^agent_uid)
    |> maybe_where_owner_session(owner_session_id)
    |> Ankole.Ash.read_one()
    |> case do
      {:ok, %Job{} = job} -> {:ok, job}
      {:ok, nil} -> {:error, :automation_job_not_found}
    end
  end

  def get_job(_agent_uid, _owner_session_id, _job_id),
    do: {:error, :automation_job_not_found}

  @doc """
  Cancels one job and every queued run in the same transaction.

  Running attempts keep their current fence and may finish or emit events.
  """
  @spec cancel_job(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, %{status: :cancelled | :already_terminal, automation_job: Job.t()}}
          | {:error, term()}
  def cancel_job(agent_uid, owner_session_id, job_id, opts \\ [])

  def cancel_job(agent_uid, owner_session_id, job_id, opts)
      when is_binary(agent_uid) and is_binary(owner_session_id) and
             Ankole.ModelIntegerID.valid?(job_id) do
    Ankole.Ash.run_action(Job, :cancel_job, %{
      agent_uid: agent_uid,
      owner_session_id: owner_session_id,
      job_id: job_id,
      now: Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    })
  end

  def cancel_job(_agent_uid, _owner_session_id, _job_id, _opts),
    do: {:error, :automation_job_not_found}

  @doc false
  def cancel_job_in_tx(repo, agent_uid, owner_session_id, job_id, now) do
    case lock_owned_job(repo, agent_uid, owner_session_id, job_id) do
      %Job{status: :active} = job ->
        job_id = job.id

        with {:ok, job} <- Ankole.Ash.update(job, :cancel, %{cancelled_at: now}),
             {:ok, _runs} <-
               Run
               |> Ash.Query.filter(automation_job_id == ^job_id and status == :queued)
               |> cancel_runs(now, "automation job was cancelled") do
          {:ok, %{status: :cancelled, automation_job: job}}
        end

      %Job{} = job ->
        {:ok, %{status: :already_terminal, automation_job: job}}

      nil ->
        {:error, :automation_job_not_found}
    end
  end

  @doc """
  Confirms that an active job belongs to the Agent that owns a trigger.
  """
  @spec validate_bindable_in_tx(module(), pos_integer() | nil, String.t()) ::
          :ok | {:error, term()}
  def validate_bindable_in_tx(_repo, nil, _agent_uid), do: :ok

  def validate_bindable_in_tx(repo, job_id, agent_uid)
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) do
    normalized_agent_uid = String.downcase(agent_uid)

    case lock_job_in_tx(repo, job_id) do
      %Job{agent_uid: owner_uid} = job when owner_uid == normalized_agent_uid ->
        if job.status == :active,
          do: :ok,
          else: {:error, {:automation_job_not_active, job.status}}

      %Job{} ->
        {:error, :automation_job_not_owned}

      nil ->
        {:error, :automation_job_not_found}
    end
  end

  def validate_bindable_in_tx(_repo, _job_id, _agent_uid),
    do: {:error, :invalid_automation_job_id}

  @doc "Locks a trigger's automation job before the trigger row in the caller's transaction."
  @spec lock_job_in_tx(module(), pos_integer()) :: Job.t() | nil
  def lock_job_in_tx(_repo, job_id) do
    Job
    |> Ash.Query.filter(id == ^job_id)
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {"automation_jobs", job_id})
  end

  @doc """
  Inserts one durable run and its Oban wake edge in the caller's transaction.
  """
  @spec enqueue_run_in_tx(module(), pos_integer(), String.t(), map(), keyword()) ::
          {:ok, enqueue_result()} | {:error, term()}
  def enqueue_run_in_tx(repo, job_id, agent_uid, event, opts \\ [])

  def enqueue_run_in_tx(repo, job_id, agent_uid, event, opts)
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) and is_map(event) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
         :ok <- Ankole.Principals.WorkAccess.check_record_in_tx(repo, Job, job_id),
         %Job{} = job <- lock_job_in_tx(repo, job_id),
         true <- job.agent_uid == String.downcase(agent_uid),
         {:ok, event} <- normalize_event(event) do
      enqueue_for_status(repo, job, event, now, opts)
    else
      nil -> {:error, :automation_job_not_found}
      false -> {:error, :automation_job_not_owned}
      {:error, _reason} = error -> error
    end
  end

  def enqueue_run_in_tx(_repo, _job_id, _agent_uid, _event, _opts),
    do: {:error, :invalid_automation_job_run}

  @doc """
  Returns the Agent of one unfinished Automation Job run, and the time since
  which the run waits for its next attempt.
  """
  @spec pending_run(pos_integer()) ::
          {:ok, %{agent_uid: String.t(), run: Run.t()}}
          | {:error, :automation_job_run_finished | :automation_job_run_not_found}
  def pending_run(run_id) when Ankole.ModelIntegerID.valid?(run_id) do
    Run
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.load(:job_agent_uid)
    |> read_one()
    |> case do
      %Run{status: status} when status in @finished_run_statuses ->
        {:error, :automation_job_run_finished}

      %Run{job_agent_uid: agent_uid} = run ->
        {:ok, %{agent_uid: agent_uid, run: run}}

      nil ->
        {:error, :automation_job_run_not_found}
    end
  end

  @impl Ankole.Sessions.AsyncWorkUnit
  def dead_letter_notice_text(%Ankole.Signals.Signal{type: type, data: data})
      when type in ["automation_job.emitted", "automation_job.run_failed"] do
    job = data["automation_job"] || %{}
    detail = data["error"] || Ankole.JSON.encode!(data["payload"])
    "Automation Job #{job["id"]} #{job["label"]}: #{detail}"
  end

  def dead_letter_notice_text(%Ankole.Signals.Signal{}), do: nil

  @doc "Admits an attempt or persists the Worker wait in the admission transaction."
  @spec start_attempt(pos_integer(), keyword()) ::
          {:ok,
           :noop
           | %{status: :waiting_for_worker, worker: AgentWorkers.AgentWorker.t() | nil}
           | %{automation_job: Job.t(), run: Run.t(), worker: AgentWorkers.AgentWorker.t() | nil}}
          | {:error, term()}
  def start_attempt(run_id, opts \\ []) when Ankole.ModelIntegerID.valid?(run_id) do
    ready_timeout_ms =
      Keyword.get_lazy(opts, :ready_timeout_ms, fn ->
        AgentWorkers.Settings.current().ready_timeout_ms
      end)

    Run
    |> Ankole.Ash.run_action(:start_attempt, %{
      run_id: run_id,
      now: Keyword.get(opts, :now, DateTime.utc_now(:microsecond)),
      ready_timeout_ms: ready_timeout_ms
    })
    |> deliver_failure()
  end

  @doc false
  def start_attempt_in_tx(repo, run_id, now, ready_timeout_ms) do
    capacity = AgentWorkers.SlotLock.capacity(:automation_jobs)

    with {:ok, {job, run}} <- lock_for_admission(repo, run_id) do
      case {job, run} do
        {%Job{}, %Run{status: status}} when status in @finished_run_statuses ->
          {:ok, :noop}

        {%Job{}, %Run{status: :running}} ->
          {:error, :automation_job_attempt_in_progress}

        {%Job{status: :active}, %Run{status: :queued}} ->
          admit_attempt_in_tx(repo, job, run, capacity, now, ready_timeout_ms)

        {%Job{} = job, %Run{} = run} ->
          start_for_status(repo, job, run, now)
      end
    else
      {:rejected, reason, job, run} -> reject_admission_in_tx(repo, job, run, reason, now)
      error -> error
    end
  end

  defp admit_attempt_in_tx(repo, job, run, capacity, now, ready_timeout_ms) do
    worker =
      case AgentWorkers.ready_worker(job.agent_uid) do
        {:ok, worker} -> worker
        {:error, :agent_worker_unavailable} -> nil
      end

    capacity_available? = capacity_available_in_tx?(repo, job, capacity)

    {status, started_at} =
      AgentWorkers.wait_status(
        worker,
        capacity_available?,
        run.worker_wait_started_at,
        now,
        ready_timeout_ms
      )

    with {:ok, run} <- persist_worker_wait_in_tx(run, started_at) do
      if not capacity_available? or status == :wait do
        {:ok, %{status: :waiting_for_worker, worker: worker}}
      else
        # An expired readiness wait starts one infrastructure-failure attempt.
        with {:ok, attempt} <- start_for_status(repo, job, run, now),
             do: {:ok, Map.put(attempt, :worker, worker)}
      end
    end
  end

  defp persist_worker_wait_in_tx(%Run{worker_wait_started_at: started_at} = run, started_at),
    do: {:ok, run}

  defp persist_worker_wait_in_tx(run, started_at),
    do: Ankole.Ash.update(run, :wait_for_worker, %{worker_wait_started_at: started_at})

  defp lock_for_admission(repo, run_id) do
    with %Run{} = snapshot <- get_run(run_id),
         %Job{} = job <- get_job_record(snapshot.automation_job_id) do
      access =
        with :ok <- Ankole.Tenants.check_work_admission_in_tx(repo, Repo.tenant_id!()),
             do: Ankole.Principals.WorkAccess.check_in_tx(repo, job)

      :ok = Ankole.AgentWorkers.SlotLock.lock(repo, :automation_jobs, job.agent_uid)
      {job, run} = lock_job_run(repo, run_id)

      case access do
        :ok ->
          {:ok, {job, run}}

        {:error, reason} ->
          {:rejected, reason, job, run}
      end
    else
      nil -> {:error, :automation_job_run_not_found}
    end
  end

  defp capacity_available_in_tx?(_repo, job, capacity) do
    agent_uid = job.agent_uid

    running =
      Run
      |> Ash.Query.filter(job.agent_uid == ^agent_uid and status == :running)
      |> Ankole.Ash.aggregate!({:count, :count})
      |> Map.fetch!(:count)

    running < capacity
  end

  defp reject_admission_in_tx(repo, job, %Run{status: :queued} = run, reason, now) do
    with {:ok, run} <-
           run
           |> Ankole.Ash.update(:settle, %{
             status: :failed,
             attempt_id: nil,
             finished_at: now,
             error: Atom.to_string(reason)
           }),
         {:ok, {_run, event}} <- maybe_append_failure_event(repo, job, run, now),
         do: {:ok, {:noop, event}}
  end

  defp reject_admission_in_tx(_repo, _job, _run, _reason, _now), do: {:ok, :noop}

  @doc false
  @spec finish_attempt(pos_integer(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Run.t() | :stale} | {:error, term()}
  def finish_attempt(run_id, attempt_id, result, opts \\ [])
      when Ankole.ModelIntegerID.valid?(run_id) and is_binary(attempt_id) and is_map(result) do
    Run
    |> Ankole.Ash.run_action(:finish_attempt, %{
      run_id: run_id,
      attempt_id: attempt_id,
      result: result,
      now: Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    })
    |> deliver_failure()
  end

  @doc false
  def finish_attempt_in_tx(repo, run_id, attempt_id, result, now) do
    with {%Job{} = job, %Run{} = run} <- lock_job_run(repo, run_id),
         true <- active_attempt?(run, attempt_id),
         {:ok, attrs} <- completion_attrs(result, now),
         {:ok, run} <- run |> Ankole.Ash.update(:settle, attrs),
         {:ok, {run, event}} <- maybe_append_failure_event(repo, job, run, now) do
      {:ok, {run, event}}
    else
      nil -> {:error, :automation_job_run_not_found}
      false -> {:ok, :stale}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec infrastructure_failure(
          pos_integer(),
          Ecto.UUID.t(),
          term(),
          :retry | :exhausted,
          keyword()
        ) :: {:ok, Run.t() | :stale} | {:error, term()}
  def infrastructure_failure(run_id, attempt_id, reason, disposition, opts \\ [])
      when Ankole.ModelIntegerID.valid?(run_id) and is_binary(attempt_id) and
             disposition in [:retry, :exhausted] do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    prefix =
      case reason do
        :execution_outcome_unknown ->
          "execution outcome unknown; verify external effects before rerunning"

        {:execution_outcome_unknown, _} ->
          "execution outcome unknown; verify external effects before rerunning"

        _ ->
          "infrastructure dispatch failed"
      end

    error = bounded_text("#{prefix}: #{inspect(reason)}", @log_max_bytes)

    Run
    |> Ankole.Ash.run_action(:infrastructure_failure, %{
      run_id: run_id,
      attempt_id: attempt_id,
      error: error,
      disposition: disposition,
      now: now
    })
    |> deliver_failure()
  end

  @doc false
  def infrastructure_failure_in_tx(repo, run_id, attempt_id, error, disposition, now) do
    with {%Job{} = job, %Run{} = run} <- lock_job_run(repo, run_id),
         true <- active_attempt?(run, attempt_id),
         {:ok, run} <-
           run
           |> Ankole.Ash.update(
             if(disposition == :retry, do: :retry, else: :settle),
             infrastructure_failure_attrs(disposition, error, now)
           ),
         {:ok, {run, event}} <- maybe_append_failure_event(repo, job, run, now) do
      {:ok, {run, event}}
    else
      nil -> {:error, :automation_job_run_not_found}
      false -> {:ok, :stale}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Appends one durable owner-session event from a live run attempt.
  """
  @spec emit_event(
          String.t(),
          pos_integer(),
          Ecto.UUID.t(),
          term(),
          keyword()
        ) :: {:ok, Ankole.Signals.Signal.t()} | {:error, term()}
  def emit_event(agent_uid, run_id, attempt_id, payload, opts \\ [])

  def emit_event(agent_uid, run_id, attempt_id, payload, opts)
      when is_binary(agent_uid) and Ankole.ModelIntegerID.valid?(run_id) and
             is_binary(attempt_id) do
    Ankole.Ash.run_action(Run, :emit_event, %{
      agent_uid: agent_uid,
      run_id: run_id,
      attempt_id: attempt_id,
      payload: payload,
      now: Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    })
  end

  def emit_event(_agent_uid, _run_id, _attempt_id, _payload, _opts),
    do: {:error, :invalid_automation_job_emit}

  @doc false
  def emit_event_in_tx(repo, agent_uid, run_id, attempt_id, payload, now) do
    with {%Job{} = job, %Run{} = run} <- lock_job_run(repo, run_id),
         true <- active_attempt?(run, attempt_id),
         true <- job.agent_uid == String.downcase(agent_uid),
         {:ok, payload} <- normalize_emitted_payload(payload),
         {:ok, signal} <-
           append_owner_event(repo, job, "automation_job.emitted", now, %{
             "automation_job" => %{"id" => job.id, "label" => job.label},
             "automation_job_run_id" => run.id,
             "payload" => payload
           }) do
      {:ok, signal}
    else
      nil -> {:error, :automation_job_run_not_found}
      false -> {:error, :automation_job_attempt_not_active}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns one job and its recent run history for the owning Agent session, or
  for any session of the Agent when `owner_session_id` is `nil`.
  """
  @spec show_job(String.t(), String.t() | nil, pos_integer(), keyword()) ::
          {:ok, %{automation_job: Job.t(), runs: [Run.t()]}} | {:error, term()}
  def show_job(agent_uid, owner_session_id, job_id, opts \\ []) do
    with {:ok, %Job{} = job} <- get_job(agent_uid, owner_session_id, job_id) do
      limit = opts |> Keyword.get(:runs, 20) |> bounded_limit(100, 20)
      job_id = job.id

      {:ok, runs} =
        Run
        |> Ash.Query.filter(automation_job_id == ^job_id)
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(limit)
        |> Ankole.Ash.read()

      {:ok, %{automation_job: job, runs: runs}}
    end
  end

  @doc """
  Returns the model-safe summary of one automation job.
  """
  @spec model_projection(Job.t()) :: map()
  def model_projection(%Job{} = job) do
    %{
      "id" => job.id,
      "label" => job.label,
      "status" => Atom.to_string(job.status),
      "wake_on_failure" => job.wake_on_failure,
      "drive_prefix" => job.drive_prefix,
      "created_at" => iso8601(job.inserted_at)
    }
  end

  @doc """
  Returns the model-safe detail and bounded run history.
  """
  @spec model_detail_projection(Job.t(), [Run.t()]) :: map()
  def model_detail_projection(%Job{} = job, runs) when is_list(runs) do
    %{
      "automation_job" => %{
        "id" => job.id,
        "agent_uid" => job.agent_uid,
        "owner_session_id" => job.owner_session_id,
        "source_signal_id" => job.source_signal_id,
        "provider_message_id" => job.provider_message_id,
        "source_provenance" => job.source_provenance || %{},
        "reply_route" => job.reply_route || %{},
        "drive_prefix" => job.drive_prefix,
        "label" => job.label,
        "wake_on_failure" => job.wake_on_failure,
        "status" => Atom.to_string(job.status),
        "cancelled_at" => iso8601(job.cancelled_at),
        "created_at" => iso8601(job.inserted_at),
        "updated_at" => iso8601(job.updated_at)
      },
      "runs" => Enum.map(runs, &run_projection/1)
    }
  end

  defp enqueue_for_status(_repo, %Job{status: :active} = job, event, _now, opts) do
    with {:ok, run} <-
           Ankole.Ash.create(Run, :enqueue, %{
             automation_job_id: job.id,
             event: event
           }),
         {:ok, _oban_job} <- insert_execution_job(run, opts) do
      {:ok, %{status: :queued, automation_job_run: run}}
    end
  end

  defp enqueue_for_status(repo, %Job{status: status} = job, event, now, _opts) do
    error = "automation job is #{status}"

    with {:ok, run} <-
           Ankole.Ash.create(Run, :record_failed, %{
             automation_job_id: job.id,
             event: event,
             finished_at: now,
             error: error
           }),
         {:ok, {run, event}} <- maybe_append_failure_event(repo, job, run, now) do
      {:ok, %{status: :failed, automation_job_run: run, signal: event}}
    end
  end

  defp insert_execution_job(%Run{} = run, opts) do
    insert = Keyword.get(opts, :wake_insert, &Oban.insert/1)

    run.id
    |> then(&ExecuteRun.new(%{"automation_job_run_id" => &1}))
    |> insert.()
  end

  defp start_for_status(_repo, %Job{status: :active} = job, run, now) do
    attempt_id = Ecto.UUID.generate()

    with {:ok, run} <-
           run
           |> Ankole.Ash.update(:start, %{
             attempt_id: attempt_id,
             started_at: now,
             finished_at: nil,
             error: nil
           }) do
      {:ok, %{automation_job: job, run: run}}
    end
  end

  defp start_for_status(repo, %Job{status: status} = job, run, now) do
    with {:ok, run} <-
           run
           |> Ankole.Ash.update(:settle, %{
             status: :failed,
             attempt_id: nil,
             finished_at: now,
             error: "automation job is #{status}"
           }),
         {:ok, {_run, event}} <- maybe_append_failure_event(repo, job, run, now) do
      {:ok, {:noop, event}}
    end
  end

  defp completion_attrs(result, now) do
    status =
      case Ankole.Attrs.get_truthy(result, "status") do
        "succeeded" -> :succeeded
        "failed" -> :failed
        _ -> nil
      end

    if status in [:succeeded, :failed] do
      {:ok,
       %{
         status: status,
         attempt_id: nil,
         finished_at: now,
         exit_code: Ankole.Attrs.get_truthy(result, "exit_code"),
         error: bounded_nullable_text(Ankole.Attrs.get_truthy(result, "error"), @log_max_bytes),
         stdout: bounded_text(Ankole.Attrs.get_truthy(result, "stdout") || "", @log_max_bytes),
         stderr: bounded_text(Ankole.Attrs.get_truthy(result, "stderr") || "", @log_max_bytes),
         stdout_truncated: Ankole.Attrs.get_truthy(result, "stdout_truncated") == true,
         stderr_truncated: Ankole.Attrs.get_truthy(result, "stderr_truncated") == true
       }}
    else
      {:error, :invalid_automation_job_result}
    end
  end

  defp infrastructure_failure_attrs(:retry, error, _now) do
    %{attempt_id: nil, error: error}
  end

  defp infrastructure_failure_attrs(:exhausted, error, now) do
    %{status: :failed, attempt_id: nil, finished_at: now, error: error}
  end

  defp maybe_append_failure_event(_repo, _job, %Run{status: status} = run, _now)
       when status != :failed,
       do: {:ok, {run, nil}}

  defp maybe_append_failure_event(_repo, %Job{wake_on_failure: false}, %Run{} = run, _now),
    do: {:ok, {run, nil}}

  defp maybe_append_failure_event(repo, %Job{} = job, %Run{} = run, now) do
    result =
      append_owner_event(repo, job, "automation_job.run_failed", now, %{
        "automation_job" => %{"id" => job.id, "label" => job.label},
        "automation_job_run_id" => run.id,
        "attempts" => run.attempts,
        "error" => run.error || "automation job run failed"
      })

    case result do
      {:ok, event} ->
        {:ok, {run, event}}

      {:error, :long_lived_reply_owner_not_found} ->
        error = bounded_text("#{run.error}; long_lived_reply_owner_not_found", @log_max_bytes)

        with {:ok, run} <- run |> Ankole.Ash.update(:record_error, %{error: error}),
             do: {:ok, {run, nil}}

      error ->
        error
    end
  end

  defp deliver_failure({:ok, {value, _event}}) do
    {:ok, value}
  end

  defp deliver_failure(result), do: result

  defp append_owner_event(repo, job, type, now, data) do
    source_event_id =
      "automation-job:#{job.id}:run:#{data["automation_job_run_id"]}:#{type}:#{Ecto.UUID.generate()}"

    with {:ok, owner} <- Route.long_lived_owner(job.agent_uid, job.owner_session_id) do
      route = owner.reply_route || job.reply_route

      Ankole.Signals.accept_in_tx(repo, %{
        producer: :kernel,
        source: "control-plane://automation-jobs/#{job.id}",
        id: source_event_id,
        type: type,
        subject: "automation_job_run:#{data["automation_job_run_id"]}",
        time: DateTime.to_iso8601(now),
        available_at: now,
        target: %{agent_uid: job.agent_uid, session_id: owner.session_id},
        sender: nil,
        authorization: Ankole.Principals.WorkAccess.fields(job),
        reply_route: %{
          binding_name: route_text(route, "binding_name"),
          conversation_id: route_text(route, "conversation_id"),
          provider_thread_id: route_text(route, "provider_thread_id"),
          provider_message_id: route_text(route, "provider_message_id") || job.provider_message_id
        },
        data: data
      })
    end
  end

  defp normalize_event(event) do
    with {:ok, event} <- JSONPayload.normalize_map(event),
         true <- byte_size(Ankole.JSON.encode!(event)) <= @payload_max_bytes do
      {:ok, event}
    else
      false -> {:error, :automation_job_event_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_emitted_payload(payload) do
    with {:ok, payload} <- JSONPayload.normalize(payload),
         true <- byte_size(Ankole.JSON.encode!(payload)) <= @payload_max_bytes do
      {:ok, payload}
    else
      false -> {:error, :automation_job_payload_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp lock_owned_job(_repo, agent_uid, owner_session_id, job_id) do
    agent_uid = String.downcase(agent_uid)

    Job
    |> Ash.Query.filter(
      id == ^job_id and agent_uid == ^agent_uid and owner_session_id == ^owner_session_id
    )
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {"automation_jobs", job_id})
  end

  # A Run keeps its parent for its entire lifetime. All paths lock Job before Run.
  defp lock_job_run(repo, run_id) do
    with %Run{automation_job_id: job_id} <- get_run(run_id),
         %Job{} = job <- lock_job_in_tx(repo, job_id),
         %Run{} = run <- lock_run(run_id) do
      {job, run}
    end
  end

  defp lock_run(run_id) do
    Run
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {"automation_job_runs", run_id})
  end

  defp get_run(run_id), do: Run |> Ash.Query.filter(id == ^run_id) |> read_one()
  defp get_job_record(job_id), do: Job |> Ash.Query.filter(id == ^job_id) |> read_one()

  defp read_one(query, opts \\ []) do
    {:ok, record} = Ankole.Ash.read_one(query, opts)
    record
  end

  defp active_attempt?(%Run{status: :running, attempt_id: attempt_id}, attempt_id), do: true
  defp active_attempt?(_run, _attempt_id), do: false

  defp run_projection(%Run{} = run) do
    %{
      "id" => run.id,
      "status" => Atom.to_string(run.status),
      "attempts" => run.attempts,
      "started_at" => iso8601(run.started_at),
      "finished_at" => iso8601(run.finished_at),
      "exit_code" => run.exit_code,
      "error" => first_line(run.error),
      "stdout" => with_truncation_marker(run.stdout, run.stdout_truncated),
      "stderr" => with_truncation_marker(run.stderr, run.stderr_truncated)
    }
  end

  defp with_truncation_marker(text, true), do: (text || "") <> "\n...[truncated]"
  defp with_truncation_marker(text, false), do: text || ""

  defp first_line(nil), do: nil
  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp bounded_nullable_text(nil, _max_bytes), do: nil
  defp bounded_nullable_text(text, max_bytes), do: bounded_text(text, max_bytes)

  defp bounded_text(text, max_bytes) when is_binary(text), do: Text.utf8_suffix(text, max_bytes)

  defp bounded_text(text, max_bytes), do: text |> inspect() |> bounded_text(max_bytes)

  defp route_text(route, key) when is_map(route) do
    case Ankole.Attrs.get_truthy(route, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp route_text(_route, _key), do: nil

  defp normalize_agent_uid(attrs) do
    case Ankole.Attrs.get_truthy(attrs, "agent_uid") do
      agent_uid when is_binary(agent_uid) ->
        attrs
        |> Map.delete("agent_uid")
        |> Map.delete(:agent_uid)
        |> Map.put(:agent_uid, String.downcase(agent_uid))

      _value ->
        attrs
    end
  end

  defp bounded_limit(value, max, _default) when is_integer(value) and value > 0,
    do: min(value, max)

  defp bounded_limit(_value, _max, default), do: default

  defp maybe_where_owner_session(query, nil), do: query

  defp maybe_where_owner_session(query, owner_session_id),
    do: Ash.Query.filter(query, owner_session_id == ^owner_session_id)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  @doc "Cancels the work of a Human whose access version is older than `version`."
  def stop_human_work_in_tx(_repo, uid, version, now) do
    {:ok, jobs} =
      Job
      |> Ash.Query.filter(human_uid == ^uid and human_access_version < ^version)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read()

    ids = Enum.map(jobs, & &1.id)

    {:ok, _jobs} =
      Job
      |> Ash.Query.filter(id in ^ids and status == :active)
      |> Ankole.Ash.update_where(:stop_human_work, %{cancelled_at: now})

    {:ok, runs} =
      Run
      |> Ash.Query.filter(automation_job_id in ^ids and status == :queued)
      |> cancel_runs(now, "human_access_revoked")

    {length(runs), nil}
  end

  defp cancel_runs(query, now, error),
    do:
      Ankole.Ash.update_where(query, :stop_human_work, %{
        attempt_id: nil,
        finished_at: now,
        error: error
      })
end
