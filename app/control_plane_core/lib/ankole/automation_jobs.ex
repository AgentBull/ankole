defmodule Ankole.AutomationJobs do
  @moduledoc """
  Owns automation job definitions, durable runs, and emitted Agent events.

  Trigger domains keep their own claim and recurrence rules. They call
  `enqueue_run_in_tx/5` inside that existing transaction when a trigger names
  an automation job.
  """

  require Ankole.ModelIntegerID

  import Ecto.Query, warn: false

  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Repo
  alias Ankole.Conversations.Route
  alias Ankole.Text

  @log_max_bytes 65_536
  @payload_max_bytes 1_048_576
  @finished_run_statuses ~w(succeeded failed cancelled)

  @type enqueue_result :: %{
          required(:status) => :queued | :failed,
          required(:automation_job_run) => Run.t(),
          optional(:signal) => Ankole.Signals.Signal.t() | nil
        }

  @doc """
  Creates one non-idempotent automation job.

  The script must already be in the Agent's drive: `drive_prefix` names a
  folder that holds `main.ts`.
  """
  @spec create_job(map()) :: {:ok, Job.t()} | {:error, term()}
  def create_job(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      attrs = Ankole.Principals.WorkAccess.inherit(repo, normalize_agent_uid(attrs))

      with :ok <- Ankole.Principals.WorkAccess.check_attrs_in_tx(repo, attrs),
           changeset = Job.changeset(%Job{}, attrs),
           :ok <- require_script_in_drive(changeset) do
        repo.insert(changeset)
      end
    end)
  end

  # The check reads the cast fields. An invalid changeset reports its own
  # errors at the insert.
  defp require_script_in_drive(%Ecto.Changeset{valid?: false}), do: :ok

  defp require_script_in_drive(changeset) do
    agent_uid = Ecto.Changeset.get_field(changeset, :agent_uid)
    prefix = Ecto.Changeset.get_field(changeset, :drive_prefix)

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

    Job
    |> maybe_where_agent(agent_uid)
    |> maybe_where_owner_session(owner_session_id)
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid),
    do: where(query, [job], job.agent_uid == ^String.downcase(agent_uid))

  @doc """
  Gets one automation job only when the Agent session owns it. A `nil`
  `owner_session_id` accepts any session of the Agent.
  """
  @spec get_job(String.t(), String.t() | nil, pos_integer()) ::
          {:ok, Job.t()} | {:error, :automation_job_not_found}
  def get_job(agent_uid, owner_session_id, job_id)
      when is_binary(agent_uid) and (is_binary(owner_session_id) or is_nil(owner_session_id)) and
             Ankole.ModelIntegerID.valid?(job_id) do
    query =
      Job
      |> where([job], job.id == ^job_id and job.agent_uid == ^String.downcase(agent_uid))
      |> maybe_where_owner_session(owner_session_id)

    case Repo.one(query) do
      %Job{} = job -> {:ok, job}
      nil -> {:error, :automation_job_not_found}
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
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_owned_job(repo, agent_uid, owner_session_id, job_id) do
        %Job{status: "active"} = job ->
          with {:ok, job} <-
                 job
                 |> Job.changeset(%{status: "cancelled", cancelled_at: now})
                 |> repo.update() do
            Run
            |> where([run], run.automation_job_id == ^job.id and run.status == "queued")
            |> repo.update_all(
              set: [
                status: "cancelled",
                attempt_id: nil,
                finished_at: now,
                error: "automation job was cancelled",
                updated_at: now
              ]
            )

            {:ok, %{status: :cancelled, automation_job: job}}
          end

        %Job{} = job ->
          {:ok, %{status: :already_terminal, automation_job: job}}

        nil ->
          {:error, :automation_job_not_found}
      end
    end)
  end

  def cancel_job(_agent_uid, _owner_session_id, _job_id, _opts),
    do: {:error, :automation_job_not_found}

  @doc """
  Confirms that an active job belongs to the Agent that owns a trigger.
  """
  @spec validate_bindable_in_tx(module(), pos_integer() | nil, String.t()) ::
          :ok | {:error, term()}
  def validate_bindable_in_tx(_repo, nil, _agent_uid), do: :ok

  def validate_bindable_in_tx(repo, job_id, agent_uid)
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) do
    normalized_agent_uid = String.downcase(agent_uid)

    case lock_job(repo, job_id) do
      %Job{agent_uid: owner_uid} = job when owner_uid == normalized_agent_uid ->
        if job.status == "active",
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
         %Job{} = job <- lock_job(repo, job_id),
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
          {:ok, %{agent_uid: String.t(), waiting_since: DateTime.t(), run: Run.t()}}
          | {:error, :automation_job_run_finished | :automation_job_run_not_found}
  def pending_run(run_id) when Ankole.ModelIntegerID.valid?(run_id) do
    Run
    |> join(:inner, [run], job in Job, on: job.id == run.automation_job_id)
    |> where([run], run.id == ^run_id)
    |> select([run, job], {run, job.agent_uid})
    |> Repo.one()
    |> case do
      {%Run{status: status}, _agent_uid} when status in @finished_run_statuses ->
        {:error, :automation_job_run_finished}

      {%Run{} = run, agent_uid} ->
        {:ok, %{agent_uid: agent_uid, waiting_since: run.updated_at, run: run}}

      nil ->
        {:error, :automation_job_run_not_found}
    end
  end

  @doc false
  @spec start_attempt(pos_integer(), keyword()) ::
          {:ok, :noop | %{automation_job: Job.t(), run: Run.t()}} | {:error, term()}
  def start_attempt(run_id, opts \\ []) when Ankole.ModelIntegerID.valid?(run_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %Run{} = snapshot <- repo.get(Run, run_id),
           :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
           :ok <-
             Ankole.Principals.WorkAccess.check_record_in_tx(
               repo,
               Job,
               snapshot.automation_job_id
             ) do
        case lock_job_run(repo, run_id) do
          {%Job{}, %Run{status: status}} when status in @finished_run_statuses ->
            {:ok, :noop}

          {%Job{}, %Run{status: "running"}} ->
            {:error, :automation_job_attempt_in_progress}

          {%Job{} = job, %Run{} = run} ->
            start_for_status(repo, job, run, now)

          nil ->
            {:error, :automation_job_run_not_found}
        end
      else
        nil -> {:error, :automation_job_run_not_found}
        error -> error
      end
    end)
    |> deliver_failure()
  end

  @doc false
  @spec finish_attempt(pos_integer(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Run.t() | :stale} | {:error, term()}
  def finish_attempt(run_id, attempt_id, result, opts \\ [])
      when Ankole.ModelIntegerID.valid?(run_id) and is_binary(attempt_id) and is_map(result) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {%Job{} = job, %Run{} = run} <- lock_job_run(repo, run_id),
           true <- active_attempt?(run, attempt_id),
           {:ok, attrs} <- completion_attrs(result, now),
           {:ok, run} <- run |> Run.changeset(attrs) |> repo.update(),
           {:ok, {run, event}} <- maybe_append_failure_event(repo, job, run, now) do
        {:ok, {run, event}}
      else
        nil -> {:error, :automation_job_run_not_found}
        false -> {:ok, :stale}
        {:error, _reason} = error -> error
      end
    end)
    |> deliver_failure()
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

    Repo.transact(fn repo ->
      with {%Job{} = job, %Run{} = run} <- lock_job_run(repo, run_id),
           true <- active_attempt?(run, attempt_id),
           {:ok, run} <-
             run
             |> Run.changeset(infrastructure_failure_attrs(disposition, error, now))
             |> repo.update(),
           {:ok, {run, event}} <- maybe_append_failure_event(repo, job, run, now) do
        {:ok, {run, event}}
      else
        nil -> {:error, :automation_job_run_not_found}
        false -> {:ok, :stale}
        {:error, _reason} = error -> error
      end
    end)
    |> deliver_failure()
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
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
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
    end)
  end

  def emit_event(_agent_uid, _run_id, _attempt_id, _payload, _opts),
    do: {:error, :invalid_automation_job_emit}

  @doc """
  Returns one job and its recent run history for the owning Agent session, or
  for any session of the Agent when `owner_session_id` is `nil`.
  """
  @spec show_job(String.t(), String.t() | nil, pos_integer(), keyword()) ::
          {:ok, %{automation_job: Job.t(), runs: [Run.t()]}} | {:error, term()}
  def show_job(agent_uid, owner_session_id, job_id, opts \\ []) do
    with {:ok, %Job{} = job} <- get_job(agent_uid, owner_session_id, job_id) do
      limit = opts |> Keyword.get(:runs, 20) |> bounded_limit(100, 20)

      runs =
        Run
        |> where([run], run.automation_job_id == ^job.id)
        |> order_by([run], desc: run.inserted_at, desc: run.id)
        |> limit(^limit)
        |> Repo.all()

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
      "status" => job.status,
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
        "status" => job.status,
        "cancelled_at" => iso8601(job.cancelled_at),
        "created_at" => iso8601(job.inserted_at),
        "updated_at" => iso8601(job.updated_at)
      },
      "runs" => Enum.map(runs, &run_projection/1)
    }
  end

  @doc """
  Returns a Console-safe detail projection.
  """
  @spec console_projection(Job.t(), [Run.t()]) :: map()
  def console_projection(%Job{} = job, runs \\ []) do
    detail = model_detail_projection(job, runs)
    Map.put(detail["automation_job"], "runs", detail["runs"])
  end

  defp enqueue_for_status(repo, %Job{status: "active"} = job, event, _now, opts) do
    with {:ok, run} <-
           %Run{}
           |> Run.changeset(%{
             automation_job_id: job.id,
             event: event,
             status: "queued",
             attempts: 0
           })
           |> repo.insert(),
         {:ok, _oban_job} <- insert_execution_job(run, opts) do
      {:ok, %{status: :queued, automation_job_run: run}}
    end
  end

  defp enqueue_for_status(repo, %Job{status: status} = job, event, now, _opts) do
    error = "automation job is #{status}"

    with {:ok, run} <-
           %Run{}
           |> Run.changeset(%{
             automation_job_id: job.id,
             event: event,
             status: "failed",
             attempts: 0,
             finished_at: now,
             error: error
           })
           |> repo.insert(),
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

  defp start_for_status(repo, %Job{status: "active"} = job, run, now) do
    attempt_id = Ecto.UUID.generate()

    with {:ok, run} <-
           run
           |> Run.changeset(%{
             status: "running",
             attempts: run.attempts + 1,
             attempt_id: attempt_id,
             started_at: run.started_at || now,
             finished_at: nil,
             error: nil
           })
           |> repo.update() do
      {:ok, %{automation_job: job, run: run}}
    end
  end

  defp start_for_status(repo, %Job{status: status} = job, run, now) do
    with {:ok, run} <-
           run
           |> Run.changeset(%{
             status: "failed",
             attempt_id: nil,
             finished_at: now,
             error: "automation job is #{status}"
           })
           |> repo.update(),
         {:ok, {_run, event}} <- maybe_append_failure_event(repo, job, run, now) do
      {:ok, {:noop, event}}
    end
  end

  defp completion_attrs(result, now) do
    status = Ankole.Attrs.get_truthy(result, "status")

    if status in ["succeeded", "failed"] do
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
    %{status: "queued", attempt_id: nil, error: error}
  end

  defp infrastructure_failure_attrs(:exhausted, error, now) do
    %{status: "failed", attempt_id: nil, finished_at: now, error: error}
  end

  defp maybe_append_failure_event(_repo, _job, %Run{status: status} = run, _now)
       when status != "failed",
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

        with {:ok, run} <- run |> Run.changeset(%{error: error}) |> repo.update(),
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

  defp lock_owned_job(repo, agent_uid, owner_session_id, job_id) do
    Job
    |> where(
      [job],
      job.id == ^job_id and job.agent_uid == ^String.downcase(agent_uid) and
        job.owner_session_id == ^owner_session_id
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_job(repo, job_id) do
    Job
    |> where([job], job.id == ^job_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # A Run keeps its parent for its entire lifetime. All paths lock Job before Run.
  defp lock_job_run(repo, run_id) do
    with %Run{automation_job_id: job_id} <- repo.get(Run, run_id),
         %Job{} = job <- lock_job(repo, job_id),
         %Run{} = run <- lock_run(repo, run_id) do
      {job, run}
    end
  end

  defp lock_run(repo, run_id) do
    Run
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp active_attempt?(%Run{status: "running", attempt_id: attempt_id}, attempt_id), do: true
  defp active_attempt?(_run, _attempt_id), do: false

  defp run_projection(%Run{} = run) do
    %{
      "id" => run.id,
      "status" => run.status,
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
    do: where(query, [job], job.owner_session_id == ^owner_session_id)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  def stop_human_work_in_tx(repo, uid, version, now) do
    jobs = from j in Job, where: j.human_uid == ^uid and j.human_access_version < ^version

    repo.update_all(from(j in jobs, where: j.status == "active"),
      set: [status: "cancelled", cancelled_at: now, updated_at: now]
    )

    repo.update_all(
      from(r in Run,
        where:
          r.automation_job_id in subquery(from j in jobs, select: j.id) and r.status == "queued"
      ),
      set: [status: "cancelled", finished_at: now, updated_at: now, error: "human_access_revoked"]
    )
  end
end
