defmodule Ankole.AutomationJobs.Jobs.ExecuteRun do
  @moduledoc """
  Oban wake edge that dispatches one durable automation job run to a worker.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      fields: [:worker, :args],
      keys: [:automation_job_run_id],
      states: :incomplete
    ]

  alias Ankole.AutomationJobs
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool

  @run_timeout_ms 600_000
  @rpc_timeout_ms @run_timeout_ms + 10_000

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, term()} | {:error, term()}
  def perform(%Oban.Job{} = job) do
    metadata = %{
      worker: __MODULE__,
      queue: job.queue,
      job_id: job.id,
      attempt: job.attempt
    }

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      result = do_perform(job)
      {result, Map.put(metadata, :result, result_status(result))}
    end)
  end

  defp do_perform(%Oban.Job{
         args: %{"automation_job_run_id" => run_id},
         attempt: oban_attempt,
         max_attempts: max_attempts
       })
       when is_integer(run_id) and run_id > 0 do
    case AutomationJobs.start_attempt(run_id) do
      {:ok, :noop} ->
        :ok

      {:ok, %{automation_job: job, run: run}} ->
        dispatch_attempt(job, run, oban_attempt, max_attempts)

      {:error, :automation_job_run_not_found} ->
        {:cancel, :automation_job_run_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_perform(%Oban.Job{}), do: {:cancel, :missing_automation_job_run_id}

  defp dispatch_attempt(job, run, oban_attempt, max_attempts) do
    request = %FabricProto.AutomationJobRunRequest{
      automation_job_run_id: Integer.to_string(run.id),
      automation_job_id: Integer.to_string(job.id),
      attempt_id: run.attempt_id,
      agent_uid: job.agent_uid,
      directory_path: job.directory_path,
      label: job.label,
      event_json: Torque.encode!(run.event),
      timeout_ms: @run_timeout_ms
    }

    with {:ok, route} <- WorkerPool.file_worker_route(),
         {:ok, payload} <-
           Broker.request_rpc(
             route,
             "automation_job.run",
             encode(request),
             timeout_ms: @rpc_timeout_ms,
             request_id: "automation-job-run-#{run.id}-#{run.attempt_id}"
           ),
         {:ok, response} <- FabricProto.AutomationJobRunResponse.decode(payload),
         {:ok, _run_or_stale} <-
           AutomationJobs.finish_attempt(run.id, run.attempt_id, %{
             status: response.status,
             exit_code: response.exit_code,
             error: blank_to_nil(response.error),
             stdout: response.stdout,
             stderr: response.stderr,
             stdout_truncated: response.stdout_truncated,
             stderr_truncated: response.stderr_truncated
           }) do
      :ok
    else
      {:error, reason} ->
        handle_infrastructure_failure(
          run,
          reason,
          oban_attempt,
          max_attempts
        )
    end
  end

  defp handle_infrastructure_failure(run, reason, attempt, max_attempts) do
    disposition = if attempt >= max_attempts, do: :exhausted, else: :retry

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

  defp encode(struct) do
    {iodata, _size} = struct.__struct__.encode!(struct)
    IO.iodata_to_binary(iodata)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp result_status(:ok), do: :ok
  defp result_status({:cancel, _reason}), do: :cancel
  defp result_status({:error, _reason}), do: :error
end
