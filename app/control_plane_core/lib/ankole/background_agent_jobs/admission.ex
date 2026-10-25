defmodule Ankole.BackgroundAgentJobs.Admission do
  @moduledoc false

  alias Ankole.AgentWorkers
  alias Ankole.BackgroundAgentJobs.JobState
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.WorkerWait
  alias Ankole.Principals.WorkAccess
  alias Ankole.Repo
  alias Ankole.Signals.Signal

  def admit_attempt_in_tx(%Job{} = snapshot, %Signal{} = event, prepare, opts) do
    # Principal rows precede the Worker, slot, and Job locks.
    access_result = admission_access(event, snapshot)
    worker = AgentWorkers.lock_in_tx(snapshot.agent_uid)

    with :ok <- Lifecycle.lock_agent_slots(snapshot.agent_uid),
         %Job{} = job <- Queries.lock_for_agent_in_tx(snapshot.id, snapshot.agent_uid) do
      cond do
        job.status in JobState.terminal_statuses() ->
          {:ok, :terminal}

        access_result != :ok ->
          access_result

        true ->
          admit_locked_in_tx(job, event, worker, prepare, opts)
      end
    else
      nil -> {:error, :job_not_found}
      error -> error
    end
  end

  defp admission_access(event, job) do
    # Closing a terminal trigger or adopting a live attempt admits no new work.
    if adopt_attempt?(event, job) or job.status in JobState.terminal_statuses() do
      :ok
    else
      with :ok <- Ankole.Tenants.check_work_admission_in_tx(Repo.tenant_id!()),
           :ok <- WorkAccess.lock_authorizers_in_tx([event, job]),
           :ok <- WorkAccess.check_in_tx(event),
           do: WorkAccess.check_in_tx(job)
    end
  end

  defp adopt_attempt?(%{last_attempt_at: %DateTime{}}, %{status: :running}), do: true
  defp adopt_attempt?(_event, _job), do: false

  defp admit_locked_in_tx(job, event, worker, prepare, opts) do
    mode = if job.status == :running, do: "adopt", else: "start"

    with {:ok, spec} <- prepare.(mode) do
      case place_and_claim_in_tx(event, job, worker, spec, mode, opts) do
        {:ok, job, worker} -> {:ok, %{job: job, worker: worker, mode: mode}}
        {:wait, reason} -> {:wait, reason, mode}
        {:error, _reason} = error -> error
      end
    end
  end

  defp place_and_claim_in_tx(_event, job, worker, _spec, "adopt", _opts) do
    if is_nil(worker) or worker.state not in [:ready, :draining] do
      {:wait, :agent_worker_unavailable}
    else
      {:ok, job, worker}
    end
  end

  defp place_and_claim_in_tx(event, job, worker, spec, "start", opts) do
    cap = Keyword.fetch!(opts, :max_running_per_agent)
    now = Keyword.fetch!(opts, :now)
    capacity_available? = Lifecycle.capacity_available_in_tx?(job, cap)

    {status, started_at} =
      AgentWorkers.wait_status(
        worker,
        capacity_available?,
        job.worker_wait_started_at,
        now,
        Keyword.fetch!(opts, :ready_timeout_ms)
      )

    with {:ok, job} <- WorkerWait.persist_in_tx(job, started_at, now) do
      cond do
        status == :wait ->
          {:wait, :agent_worker_unavailable}

        not capacity_available? ->
          {:wait, :background_agent_job_agent_at_capacity}

        status == :timed_out ->
          {:wait, :agent_worker_ready_timeout}

        true ->
          reserve_and_claim_in_tx(event, job, spec, cap)
      end
    end
  end

  defp reserve_and_claim_in_tx(event, job, spec, cap) do
    with {:ok, worker} <- AgentWorkers.reserve_slot_in_tx(job.agent_uid),
         {:ok, job} <- claim(event, job, spec, cap) do
      {:ok, job, worker}
    else
      {:error, :no_worker_capacity} -> {:wait, :no_worker_capacity}
      error -> error
    end
  end

  defp claim(%Signal{producer: :kernel, type: "command.steer"}, job, spec, cap),
    do: Lifecycle.claim_continuation_in_tx(job.id, job.agent_uid, job.attempts + 1, spec, cap)

  defp claim(_event, job, spec, cap),
    do: Lifecycle.claim_attempt_in_tx(job.id, job.agent_uid, job.attempts + 1, spec, cap)
end
