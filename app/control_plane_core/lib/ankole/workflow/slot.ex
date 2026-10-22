defmodule Ankole.Workflow.Slot do
  @moduledoc "Owns workflow capacity and ordered row locks."
  import Ecto.Query, warn: false
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  def enforce_capacity(repo, run, max_running_per_agent) do
    run_running =
      repo.aggregate(
        from(call in AgentCall, where: call.run_id == ^run.id and call.status == :running),
        :count
      )

    agent_running =
      repo.aggregate(
        from(call in AgentCall,
          where: call.agent_uid == ^run.agent_uid and call.status == :running
        ),
        :count
      )

    if run_running < run.concurrency and agent_running < max_running_per_agent do
      :ok
    else
      {:error, :workflow_agent_at_capacity}
    end
  end

  def lock_agent_slots(repo, agent_uid) do
    Ankole.AgentWorkers.SlotLock.lock(repo, :workflow, agent_uid)
  end

  def lock_session_work_in_tx(repo, agent_uid, session_id) do
    with {:ok, call_id} <- Ankole.Workflow.Queries.parse_task_session_id(session_id),
         :ok <- lock_agent_slots(repo, agent_uid),
         {:ok, run_id} <- call_run_id(repo, call_id, agent_uid),
         %Run{} = run <- lock_run(repo, run_id, agent_uid),
         %AgentCall{} = call <- lock_call(repo, call_id, run_id, agent_uid) do
      lock_run_calls(repo, run_id)
      {:ok, %{run: run, call: call}}
    else
      nil -> {:error, :workflow_task_not_found}
      error -> error
    end
  end

  def call_run_id(repo, call_id, agent_uid) do
    AgentCall
    |> where([call], call.id == ^call_id and call.agent_uid == ^agent_uid)
    |> select([call], call.run_id)
    |> repo.one()
    |> case do
      run_id when is_integer(run_id) -> {:ok, run_id}
      nil -> {:error, :workflow_task_not_found}
    end
  end

  def lock_run(repo, run_id) do
    Run
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> repo.one(lock_identity: {"workflow_runs", run_id})
  end

  def lock_run(repo, run_id, agent_uid) do
    Run
    |> where([run], run.id == ^run_id and run.agent_uid == ^agent_uid)
    |> lock("FOR UPDATE")
    |> repo.one(lock_identity: {"workflow_runs", run_id})
  end

  def lock_call(repo, call_id, run_id, agent_uid) do
    AgentCall
    |> where(
      [call],
      call.id == ^call_id and call.run_id == ^run_id and call.agent_uid == ^agent_uid
    )
    |> lock("FOR UPDATE")
    |> repo.one(lock_identity: {"workflow_agent_calls", call_id})
  end

  def lock_run_calls(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id)
    |> order_by([call], asc: call.id)
    |> lock("FOR UPDATE")
    |> repo.lock_all("workflow_agent_calls")
  end

  def lock_run_calls_by_sequence(repo, run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id)
    |> order_by([call], asc: call.call_seq)
    |> lock("FOR UPDATE")
    |> repo.lock_all("workflow_agent_calls")
  end
end
