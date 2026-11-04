defmodule Ankole.AutomationJobs.Lifecycle do
  @moduledoc "Durable Action Run settlement, recovery and revocation."
  require Ash.Query
  require Ankole.ModelIntegerID
  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.{Queue, Schemas.Job, Schemas.Run}
  alias Ankole.{Repo, Text}
  @log_max_bytes 65_536
  @finished_run_statuses [:succeeded, :failed, :cancelled]

  def count_running_runs_for_human(uid, version) do
    job_ids =
      Job
      |> Ash.Query.filter(human_uid == ^uid and human_access_version < ^version)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)

    Run
    |> Ash.Query.filter(automation_job_id in ^job_ids and status == :running)
    |> Ankole.Ash.count!()
  end

  @doc "Authorizes an Applet Job consumer using its Page and personal-work scope."
  def authorize_bindable_in_tx(_actor, nil), do: :ok

  def authorize_bindable_in_tx(uid, job_id) when is_binary(uid) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid),
         do: authorize_bindable_in_tx(Ankole.AuthZ.Actor.new(principal), job_id)
  end

  def authorize_bindable_in_tx(%Ankole.AuthZ.Actor{} = actor, job_id)
      when Ankole.ModelIntegerID.valid?(job_id) do
    case lock_job_in_tx(job_id) do
      %Job{status: :active} = job ->
        AutomationJobs.authorize_applet_job(actor, job, job.page_id, "node_contribute")

      %Job{} = job ->
        {:error, {:automation_job_not_active, job.status}}

      nil ->
        {:error, :automation_job_not_found}
    end
  end

  def authorize_bindable_in_tx(_, _), do: {:error, :invalid_automation_job_id}

  @doc "Locks a trigger's automation job before the trigger row in the caller's transaction."
  @spec lock_job_in_tx(pos_integer()) :: Job.t() | nil
  def lock_job_in_tx(job_id) do
    Job
    |> Ash.Query.filter(id == ^job_id)
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {"automation_jobs", job_id})
  end

  def pending_run(run_id) do
    case get_run_record(run_id) do
      %Run{status: status} when status in @finished_run_statuses ->
        {:error, :automation_job_run_finished}

      %Run{} = run ->
        {:ok, %{run: run}}

      nil ->
        {:error, :automation_job_run_not_found}
    end
  end

  @doc false
  @spec finish_attempt(pos_integer(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Run.t() | :stale} | {:error, term()}
  def finish_attempt(run_id, attempt_id, result, opts \\ [])
      when Ankole.ModelIntegerID.valid?(run_id) and is_binary(attempt_id) and is_map(result) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact_top_level(
      fn ->
        finish_attempt_in_tx(run_id, attempt_id, result, now)
      end,
      after_commit: fn _ -> AutomationJobs.publish_run(run_id) end
    )
  end

  @doc false
  def finish_attempt_in_tx(run_id, attempt_id, result, now) do
    with {%Job{} = job, %Run{} = run} <- lock_job_run(run_id),
         true <- active_attempt?(run, attempt_id),
         {:ok, attrs} <- completion_attrs(result, now),
         {:ok, run} <- run |> Ankole.Ash.update(:settle, attrs),
         :ok <- Queue.wake_next(job, run) do
      {:ok, run}
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

    Repo.transact_top_level(
      fn ->
        infrastructure_failure_in_tx(run_id, attempt_id, error, disposition, now)
      end,
      after_commit: fn _ -> AutomationJobs.publish_run(run_id) end
    )
  end

  @doc false
  def infrastructure_failure_in_tx(run_id, attempt_id, error, disposition, now) do
    with {%Job{} = job, %Run{} = run} <- lock_job_run(run_id),
         true <- active_attempt?(run, attempt_id),
         recover? =
           disposition == :exhausted and run.attempt_idempotent and run.attempts_in_slice < 10,
         disposition = if(recover?, do: :retry, else: disposition),
         {:ok, run} <-
           run
           |> Ankole.Ash.update(
             if(disposition == :retry, do: :retry, else: :settle),
             infrastructure_failure_attrs(disposition, error, now)
           ),
         :ok <- if(recover?, do: Queue.insert(run), else: :ok),
         :ok <- if(run.status == :failed, do: Queue.wake_next(job, run), else: :ok) do
      {:ok, run}
    else
      nil -> {:error, :automation_job_run_not_found}
      false -> {:ok, :stale}
      {:error, _reason} = error -> error
    end
  end

  @doc "Recovers or settles abandoned Action attempts after their persisted deadline."
  @spec expire_attempts(keyword()) :: :ok | {:error, term()}
  def expire_attempts(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Run
    |> Ash.Query.filter(status == :running and attempt_deadline_at <= ^now)
    |> Ash.Query.sort(started_at: :asc, id: :asc)
    |> Ash.Query.limit(100)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn run, :ok ->
      case infrastructure_failure(
             run.id,
             run.attempt_id,
             :execution_outcome_unknown,
             :exhausted,
             now: now
           ) do
        {:ok, _run_or_stale} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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
         result: Ankole.Attrs.get(result, :result),
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

  # A Run keeps its parent for its entire lifetime. All paths lock Job before Run.
  defp lock_job_run(run_id) do
    with %Run{automation_job_id: job_id} <- get_run_record(run_id),
         %Job{} = job <- lock_job_in_tx(job_id),
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

  def get_run_record(run_id), do: Run |> Ash.Query.filter(id == ^run_id) |> read_one()

  defp read_one(query, opts \\ []) do
    {:ok, record} = Ankole.Ash.read_one(query, opts)
    record
  end

  defp active_attempt?(%Run{status: :running, attempt_id: attempt_id}, attempt_id), do: true
  defp active_attempt?(_run, _attempt_id), do: false

  defp bounded_nullable_text(nil, _max_bytes), do: nil
  defp bounded_nullable_text(text, max_bytes), do: bounded_text(text, max_bytes)

  defp bounded_text(text, max_bytes) when is_binary(text), do: Text.utf8_suffix(text, max_bytes)

  defp bounded_text(text, max_bytes), do: text |> inspect() |> bounded_text(max_bytes)

  @doc "Cancels the work of a Human whose access version is older than `version`."
  def stop_human_work_in_tx(uid, version, now) do
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
