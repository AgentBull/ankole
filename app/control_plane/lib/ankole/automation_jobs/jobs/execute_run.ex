defmodule Ankole.AutomationJobs.Jobs.ExecuteRun do
  @moduledoc "Executes one Function Runtime Action slice under its durable attempt fence."

  use Ankole.Job,
    tenancy: :tenant,
    queue: :automation_jobs,
    max_attempts: 5,
    unique: [
      fields: [:worker, :args],
      keys: [:automation_job_run_id, :expected_slice_count],
      states: [:available, :scheduled, :retryable]
    ]

  alias Ankole.AutomationJobs

  @retry_delay_seconds 10

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) ::
          :ok | {:cancel, term()} | {:error, term()} | {:snooze, pos_integer()}
  def run(%Oban.Job{args: %{"automation_job_run_id" => run_id}} = oban_job)
      when is_integer(run_id) and run_id > 0 do
    expected_slice = oban_job.args["expected_slice_count"] || 0

    result =
      case AutomationJobs.pending_run(run_id) do
        {:ok, %{run: run}} when run.slice_count != expected_slice ->
          :ok

        {:ok, %{run: %{status: :running} = run}} ->
          await_running_attempt(run, oban_job)

        {:ok, _pending} ->
          start_applet(run_id, oban_job)

        {:error, :automation_job_run_finished} ->
          :ok

        {:error, :automation_job_run_not_found} ->
          {:cancel, :automation_job_run_not_found}
      end

    AutomationJobs.publish_run(run_id)
    result
  end

  def run(%Oban.Job{}), do: {:cancel, :missing_automation_job_run_id}

  defp await_running_attempt(run, oban_job) do
    if DateTime.compare(DateTime.utc_now(), run.attempt_deadline_at) == :lt do
      {:snooze, @retry_delay_seconds}
    else
      handle_infrastructure_failure(run, :execution_outcome_unknown, oban_job, :exhausted)
    end
  end

  defp start_applet(run_id, oban_job) do
    with {:ok, attempt} when is_map(attempt) <-
           AutomationJobs.start_applet_attempt(run_id, oban_job.args["expected_slice_count"] || 0) do
      AutomationJobs.publish_run(run_id)

      case AutomationJobs.execute_applet_attempt(attempt) do
        {:rejected, %{"body" => %{"error" => %{"code" => "applet_busy"}}}} ->
          with {:ok, _} <- AutomationJobs.defer_applet_attempt(attempt),
               do: {:snooze, @retry_delay_seconds}

        {:rejected, outcome} ->
          handle_infrastructure_failure(attempt.run, outcome["body"]["error"]["code"], oban_job)

        {:completed, %{"status" => 200, "continueSlice" => options}} ->
          context = %{
            "job" => %{"id" => attempt.automation_job.id},
            "run" => %{"id" => attempt.run.id, "attemptId" => attempt.run.attempt_id}
          }

          case AutomationJobs.continue_applet_slice(context, options) do
            {:ok, _} -> :ok
            {:error, reason} -> finish_applet(attempt.run, "failed", nil, inspect(reason))
          end

        {:completed, %{"status" => status} = outcome} ->
          error =
            case outcome["body"] do
              %{"error" => %{"code" => code}} when status >= 400 -> code
              _ -> nil
            end

          finish_applet(
            attempt.run,
            if(status < 400, do: "succeeded", else: "failed"),
            outcome["body"],
            error
          )

        {:aborted, outcome} ->
          handle_infrastructure_failure(
            attempt.run,
            {:execution_outcome_unknown, outcome["body"]["error"]["code"]},
            oban_job,
            :exhausted
          )
      end
    else
      {:ok, :noop} ->
        :ok

      {:error, reason} when reason in [:applet_busy, :applet_revision_changed] ->
        {:snooze, @retry_delay_seconds}

      error ->
        error
    end
  end

  defp finish_applet(run, status, result, error) do
    case AutomationJobs.finish_attempt(run.id, run.attempt_id, %{
           status: status,
           result: result,
           error: error
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp handle_infrastructure_failure(run, reason, oban_job, disposition \\ nil) do
    disposition =
      disposition || if oban_job.attempt >= oban_job.max_attempts, do: :exhausted, else: :retry

    case AutomationJobs.infrastructure_failure(
           run.id,
           run.attempt_id,
           reason,
           disposition
         ) do
      {:ok, :stale} ->
        :ok

      {:ok, _run} when disposition == :exhausted ->
        :ok

      {:ok, _run} ->
        {:error, reason}

      {:error, failure_reason} ->
        {:error, {:automation_job_failure_record_failed, failure_reason}}
    end
  end
end
