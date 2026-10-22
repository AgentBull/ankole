defmodule Ankole.BackgroundAgentJobs.WorkerWait do
  @moduledoc false

  alias Ankole.AgentWorkers
  alias Ankole.BackgroundAgentJobs.JobState
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Wakeups
  alias Ankole.Repo
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal

  @poll_interval_seconds 30

  @doc false
  @spec clear(map()) :: map()
  def clear(%{"status" => _} = attrs), do: Map.put(attrs, "worker_wait_started_at", nil)

  def clear(%{} = attrs), do: Map.put(attrs, :worker_wait_started_at, nil)

  @doc false
  def persist_in_tx(%Job{worker_wait_started_at: started_at} = job, started_at, _now),
    do: {:ok, job}

  def persist_in_tx(%Job{} = job, nil, now), do: JobState.clear_worker_wait_in_tx(job, now)

  def persist_in_tx(%Job{} = job, %DateTime{} = started_at, _now),
    do: JobState.begin_worker_wait_in_tx(job, started_at)

  @doc false
  @spec defer_in_tx(module(), Signal.t(), atom(), String.t(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def defer_in_tx(_repo, _event, :agent_worker_ready_timeout, _mode, _now),
    do: {:error, :agent_worker_ready_timeout}

  def defer_in_tx(repo, event, reason, mode, now) do
    retry_at = DateTime.add(now, @poll_interval_seconds, :second)

    with :ok <-
           Ankole.Sessions.Jobs.EnsureDriver.enqueue_in_tx(
             repo,
             %{agent_uid: event.agent_uid, session_id: event.session_id},
             retry_at
           ) do
      {:ok,
       %{
         status: :waiting_for_worker,
         reason: reason,
         mode: mode,
         signal: event,
         retry_at: retry_at
       }}
    end
  end

  @doc false
  @spec resolve_timeout(Signal.t(), Job.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def resolve_timeout(%Signal{} = event, %Job{} = snapshot, %DateTime{} = now) do
    Repo.transact(fn repo ->
      _worker = AgentWorkers.lock_in_tx(repo, snapshot.agent_uid)

      with :ok <- Lifecycle.lock_agent_slots(repo, snapshot.agent_uid),
           %Job{} = job <-
             Queries.get_for_agent(repo, snapshot.id, snapshot.agent_uid, lock: "FOR UPDATE") do
        case job.status do
          :queued ->
            with {:ok, compensation} <-
                   Lifecycle.commit_status_after_runtime_prefix_in_tx(
                     repo,
                     job.id,
                     job.agent_uid,
                     %{
                       "status" => :failed,
                       "error" => %{
                         "code" => "agent_worker_unavailable",
                         "summary" => "Job admission was rejected."
                       }
                     },
                     now,
                     nil,
                     nil,
                     external_completion: true,
                     transition_action: :fail_admission
                   ),
                 {:ok, event} <-
                   Queue.mark_event_dead_letter_in_tx(repo, event, now, %{
                     "code" => "agent_worker_unavailable",
                     "reason" => "agent_worker_ready_timeout"
                   }) do
              {:ok,
               %{
                 status: :dead_letter,
                 signal: event,
                 wakeup_event: compensation[:wakeup_event]
               }}
            end

          :waiting_on_user ->
            with :ok <- Lifecycle.lock_job_sessions_in_tx(repo, job),
                 {:ok, job} <-
                   JobState.clear_worker_wait_in_tx(job, now),
                 {:ok, event} <-
                   Queue.mark_event_dead_letter_in_tx(repo, event, now, %{
                     "code" => "agent_worker_unavailable",
                     "reason" => "agent_worker_ready_timeout"
                   }),
                 {:ok, wakeup_event} <-
                   Wakeups.enqueue_input_undeliverable_in_tx(repo, job, event, now) do
              {:ok,
               %{
                 status: :dead_letter,
                 signal: event,
                 wakeup_event: wakeup_event
               }}
            end

          status when status in [:succeeded, :failed, :stopped] ->
            with {:ok, event} <- Queue.mark_event_completed_in_tx(repo, event, now) do
              {:ok, %{status: :idle, signal: event}}
            end

          _running ->
            {:ok, %{status: :idle, signal: event}}
        end
      else
        nil -> {:error, :job_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end
end
