defmodule Ankole.Workflow.Recovery do
  @moduledoc "Repairs lost workflow wakeups and stale task attempts."
  require Ash.Query
  alias Ankole.Repo
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @doc """
  Wakes the owner process of each run that still needs replay or cleanup.

  The function reads the runs of every tenant and inserts one idempotent
  `PokeRun` job for each run without a live owner. A failed insert stops the
  pass; the next pass repeats it.
  """
  def reconcile_run_wakeups do
    terminal = Run.terminal_statuses()

    runs =
      Repo.across_tenants(fn ->
        Run
        |> Ash.Query.for_read(:work_across_tenants, %{}, authorize?: false)
        |> Ash.Query.filter(
          status == :running or (status in ^terminal and is_nil(cleanup_completed_at))
        )
        |> Ash.read!(authorize?: false)
      end)

    runs
    |> Enum.reject(&RunServer.whereis(&1.id))
    |> Enum.reduce_while(:ok, fn run, :ok ->
      case Repo.with_tenant(run.tenant_id, fn ->
             Ankole.Workflow.Jobs.PokeRun.enqueue_in_tx(Repo, run.id)
           end) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  def reconcile_stale_tasks_in_tx(repo, run_id, %DateTime{} = cutoff, %DateTime{} = reconciled_at)
      when is_integer(run_id) and run_id > 0 do
    with {:ok, %Run{} = snapshot} <-
           Run |> Ash.Query.filter(id == ^run_id) |> Ankole.Ash.read_one(),
         :ok <- Ankole.Workflow.Slot.lock_agent_slots(repo, snapshot.agent_uid),
         %Run{} = run <- Ankole.Workflow.Slot.lock_run(repo, run_id, snapshot.agent_uid) do
      if run.status == :running do
        reconcile_running_tasks_in_tx(repo, run, cutoff, reconciled_at)
      else
        {:ok, %{run: run, reconciled: 0, running_session_ids: []}}
      end
    else
      nil -> {:error, :workflow_not_found}
      {:ok, nil} -> {:error, :workflow_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_overdue_sleeping(_repo, %Run{status: status} = run, _cutoff, _now)
       when status != :running do
    {:ok, 0, run}
  end

  defp reconcile_overdue_sleeping(repo, run, cutoff, now) do
    run_id = run.id

    calls =
      AgentCall
      |> Ash.Query.filter(run_id == ^run_id and status == :sleeping and wake_at < ^cutoff)
      |> Ash.Query.sort(call_seq: :asc)
      |> Ankole.Workflow.Slot.lock_calls()

    Enum.reduce_while(calls, {:ok, 0, run}, fn call, {:ok, count, current_run} ->
      case recover_overdue_sleeping(repo, current_run, call, now) do
        :notified ->
          {:cont, {:ok, count + 1, current_run}}

        {:ok, %{run: %Run{} = next_run}} ->
          next = {:ok, count + 1, next_run}

          if next_run.status == :running do
            {:cont, next}
          else
            {:halt, next}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp recover_overdue_sleeping(repo, run, call, now) do
    if open_task_event?(repo, call) do
      case Ankole.Workflow.TaskLifecycle.notify_task_ready(repo, call, now) do
        :ok -> :notified
        {:error, _reason} = error -> error
      end
    else
      failure = %{
        "code" => "workflow_task_wake_lost",
        "summary" => "The Workflow task lost its wake event after its sleep deadline.",
        "retryable" => false
      }

      Ankole.Workflow.TaskLifecycle.commit_failure(repo, run, call, failure, false, now)
    end
  end

  defp open_task_event?(repo, call) do
    session_id = Ankole.Workflow.Queries.task_session_id(call.id)
    not is_nil(Ankole.Sessions.Queue.oldest_open(repo, call.agent_uid, session_id))
  end

  defp reconcile_running_tasks_in_tx(repo, run, cutoff, reconciled_at) do
    run_id = run.id

    calls =
      AgentCall
      |> Ash.Query.filter(run_id == ^run_id and status == :running and progress_at < ^cutoff)
      |> Ash.Query.sort(call_seq: :asc)
      |> Ankole.Workflow.Slot.lock_calls()

    calls
    |> Enum.reduce_while({:ok, 0, run, [], false}, fn call,
                                                      {:ok, count, current_run, running_ids,
                                                       released?} ->
      failure = %{
        "code" => "workflow_task_stale",
        "summary" => "The Workflow task Turn did not finish before the one-hour watchdog.",
        "retryable" => true
      }

      case Ankole.Workflow.TaskLifecycle.commit_failure(
             repo,
             current_run,
             call,
             failure,
             call.attempts < 3,
             reconciled_at
           ) do
        {:ok, %{run: %Run{} = next_run} = result} ->
          next =
            {:ok, count + 1, next_run, Map.get(result, :running_session_ids, []) ++ running_ids,
             released? or Map.get(result, :released_slot?, false)}

          if next_run.status == :running do
            {:cont, next}
          else
            {:halt, next}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, count, current_run, running_ids, released?} ->
        with {:ok, overdue_count, current_run} <-
               reconcile_overdue_sleeping(repo, current_run, cutoff, reconciled_at) do
          {:ok,
           %{
             run: current_run,
             reconciled: count + overdue_count,
             running_session_ids: Enum.reverse(running_ids),
             released_slot?: released?
           }}
        end

      {:error, _reason} = error ->
        error
    end
  end
end
