defmodule Ankole.AutomationJobs.Jobs.ExecuteRun do
  @moduledoc """
  Oban wake edge that dispatches one durable automation job run to the
  Worker of the job's Agent.

  The run waits while that Worker is not ready: the job requests the Worker
  and snoozes, which does not consume an attempt, and the attempt starts when
  the Worker can take it. A Worker that is still not ready
  `agent_computer.worker.ready_timeout` after the run became queued counts as
  one infrastructure failure, so a Worker that cannot start fails the run
  within the attempt budget. A run that finished or was cancelled meanwhile
  ends the job without a Worker.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 5,
    unique: [
      fields: [:worker, :args],
      keys: [:automation_job_run_id],
      states: :incomplete
    ]

  alias Ankole.AIAgent.Library
  alias Ankole.AutomationJobs
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.Settings, as: WorkerSettings
  alias Ankole.AgentWorkers.RPCWire
  alias Ankole.AgentWorkers.WorkerRoute

  @worker_wait_seconds 10

  @run_timeout_ms 600_000
  @rpc_timeout_ms @run_timeout_ms + 10_000

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) ::
          :ok | {:cancel, term()} | {:error, term()} | {:snooze, pos_integer()}
  def run(%Oban.Job{args: %{"automation_job_run_id" => run_id}} = oban_job)
      when is_integer(run_id) and run_id > 0 do
    case AutomationJobs.pending_run(run_id) do
      {:ok, %{run: %{status: "running"} = run}} -> await_running_attempt(run, oban_job)
      {:ok, pending} -> start_when_ready(run_id, pending, oban_job)
      {:error, :automation_job_run_finished} -> :ok
      {:error, :automation_job_run_not_found} -> {:cancel, :automation_job_run_not_found}
    end
  end

  def run(%Oban.Job{}), do: {:cancel, :missing_automation_job_run_id}

  # A prior wake may have sent the script before its process or node died.
  # Keep its attempt fence; starting another attempt could repeat effects.
  defp await_running_attempt(run, oban_job) do
    if DateTime.diff(DateTime.utc_now(), run.started_at, :millisecond) < @rpc_timeout_ms do
      {:snooze, @worker_wait_seconds}
    else
      handle_infrastructure_failure(run, :execution_outcome_unknown, oban_job, :exhausted)
    end
  end

  defp start_when_ready(run_id, pending, oban_job) do
    case AgentWorkers.ready_worker(pending.agent_uid) do
      {:ok, _worker} = ready ->
        start_attempt(run_id, ready, oban_job)

      {:error, :agent_worker_unavailable} = unavailable ->
        :ok = AgentWorkers.request(pending.agent_uid)

        if waited_out?(pending.waiting_since),
          do: start_attempt(run_id, unavailable, oban_job),
          else: {:snooze, @worker_wait_seconds}
    end
  end

  defp waited_out?(waiting_since) do
    DateTime.diff(DateTime.utc_now(), waiting_since, :millisecond) >=
      WorkerSettings.current().ready_timeout_ms
  end

  defp start_attempt(run_id, worker, oban_job) do
    case AutomationJobs.start_attempt(run_id) do
      {:ok, :noop} ->
        :ok

      {:ok, %{automation_job: job, run: run}} ->
        case worker do
          {:ok, worker} -> dispatch_attempt(worker, job, run, oban_job)
          {:error, reason} -> handle_infrastructure_failure(run, reason, oban_job)
        end

      {:error, :automation_job_run_not_found} ->
        {:cancel, :automation_job_run_not_found}

      {:error, :automation_job_attempt_in_progress} ->
        {:snooze, @worker_wait_seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_attempt(worker, job, run, oban_job) do
    case Library.runtime_skills_for_agent(job.agent_uid) do
      {:ok, skills} -> dispatch_prepared(worker, job, run, skills, oban_job)
      {:error, reason} -> handle_infrastructure_failure(run, reason, oban_job)
    end
  end

  defp dispatch_prepared(worker, job, run, skills, oban_job) do
    request = run_request(job, run, skills)

    with {:ok, payload} <-
           WorkerRoute.request_rpc(
             AgentWorkers.target(worker),
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
      {:error, %{"details_json" => %{"execution_started" => false}} = reason} ->
        handle_infrastructure_failure(run, reason, oban_job)

      {:error, reason} ->
        handle_infrastructure_failure(
          run,
          {:execution_outcome_unknown, reason},
          oban_job,
          :exhausted
        )
    end
  end

  defp run_request(job, run, skills) do
    %FabricProto.AutomationJobRunRequest{
      automation_job_run_id: Integer.to_string(run.id),
      automation_job_id: Integer.to_string(job.id),
      attempt_id: run.attempt_id,
      drive_prefix: job.drive_prefix,
      label: job.label,
      event_json: Torque.encode!(run.event),
      timeout_ms: @run_timeout_ms,
      skills: Enum.map(skills, &RPCWire.runtime_skill_summary/1),
      binding_name: reply_route_text(job.reply_route, "binding_name")
    }
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

  defp encode(struct) do
    {iodata, _size} = struct.__struct__.encode!(struct)
    IO.iodata_to_binary(iodata)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp reply_route_text(route, key) when is_map(route) do
    case Map.get(route, key) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp reply_route_text(_route, _key), do: ""
end
