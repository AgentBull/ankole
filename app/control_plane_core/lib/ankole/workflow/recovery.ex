defmodule Ankole.Workflow.Recovery do
  @moduledoc "Repairs lost workflow wakeups and stale task attempts."
  import Ecto.Query, warn: false
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  def reconcile_run_wakeups do
    terminal = Run.terminal_statuses()

    Repo.transact(fn repo ->
      runs =
        Repo.across_tenants(fn ->
          from(run in Run,
            where:
              run.status == :running or
                (run.status in ^terminal and is_nil(run.cleanup_completed_at)),
            select: %{id: run.id, tenant_id: run.tenant_id}
          )
          |> repo.all()
        end)

      runs
      |> Enum.reject(&RunServer.whereis(&1.id))
      |> Enum.reduce_while({:ok, :ok}, fn run, result ->
        case Repo.with_tenant(run.tenant_id, fn ->
               Ankole.Workflow.Jobs.PokeRun.enqueue_in_tx(repo, run.id)
             end) do
          :ok -> {:cont, result}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def reconcile_stale_tasks(run_id, %DateTime{} = cutoff, %DateTime{} = reconciled_at)
      when is_integer(run_id) and run_id > 0 do
    Repo.transact(fn repo ->
      with %Run{} = snapshot <- repo.get(Run, run_id),
           :ok <- Ankole.Workflow.Slot.lock_agent_slots(repo, snapshot.agent_uid),
           %Run{} = run <- Ankole.Workflow.Slot.lock_run(repo, run_id, snapshot.agent_uid) do
        if run.status == :running do
          reconcile_running_tasks_in_tx(repo, run, cutoff, reconciled_at)
        else
          {:ok, %{run: run, reconciled: 0, running_session_ids: []}}
        end
      else
        nil -> {:error, :workflow_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp reconcile_overdue_sleeping(_repo, %Run{status: status} = run, _cutoff, _now)
       when status != :running do
    {:ok, 0, run}
  end

  defp reconcile_overdue_sleeping(repo, run, cutoff, now) do
    calls =
      AgentCall
      |> where(
        [call],
        call.run_id == ^run.id and call.status == :sleeping and call.wake_at < ^cutoff
      )
      |> order_by([call], asc: call.call_seq)
      |> lock("FOR UPDATE")
      |> repo.lock_all("workflow_agent_calls")

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

    Signal
    |> where(
      [event],
      event.agent_uid == ^call.agent_uid and event.session_id == ^session_id and
        event.status in [:queued, :running]
    )
    |> repo.exists?()
  end

  defp reconcile_running_tasks_in_tx(repo, run, cutoff, reconciled_at) do
    calls =
      AgentCall
      |> where(
        [call],
        call.run_id == ^run.id and call.status == :running and call.progress_at < ^cutoff
      )
      |> order_by([call], asc: call.call_seq)
      |> lock("FOR UPDATE")
      |> repo.lock_all("workflow_agent_calls")

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
