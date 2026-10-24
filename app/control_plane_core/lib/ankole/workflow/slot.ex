defmodule Ankole.Workflow.Slot do
  @moduledoc "Owns workflow capacity and ordered row locks."
  require Ash.Query
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  def enforce_capacity(run, max_running_per_agent) do
    run_id = run.id
    agent_uid = run.agent_uid

    run_running =
      AgentCall
      |> Ash.Query.filter(run_id == ^run_id and status == :running)
      |> Ankole.Ash.count!()

    agent_running =
      AgentCall
      |> Ash.Query.filter(agent_uid == ^agent_uid and status == :running)
      |> Ankole.Ash.count!()

    if run_running < run.concurrency and agent_running < max_running_per_agent do
      :ok
    else
      {:error, :workflow_agent_at_capacity}
    end
  end

  def lock_agent_slots(agent_uid) do
    Ankole.AgentWorkers.SlotLock.lock(:workflow, agent_uid)
  end

  def lock_session_work_in_tx(agent_uid, session_id) do
    with {:ok, call_id} <- Ankole.Workflow.Queries.parse_task_session_id(session_id),
         :ok <- lock_agent_slots(agent_uid),
         {:ok, run_id} <- call_run_id(call_id, agent_uid),
         %Run{} = run <- lock_run(run_id, agent_uid),
         %AgentCall{} = call <- lock_call(call_id, run_id, agent_uid) do
      lock_run_calls(run_id)
      {:ok, %{run: run, call: call}}
    else
      nil -> {:error, :workflow_task_not_found}
      error -> error
    end
  end

  def call_run_id(call_id, agent_uid) do
    AgentCall
    |> Ash.Query.filter(id == ^call_id and agent_uid == ^agent_uid)
    |> Ash.Query.select([:run_id])
    |> one()
    |> case do
      %AgentCall{run_id: run_id} -> {:ok, run_id}
      nil -> {:error, :workflow_task_not_found}
    end
  end

  @doc "Reads one run of an Agent without a lock, or `nil`."
  def get_run(run_id, agent_uid),
    do: Run |> Ash.Query.filter(id == ^run_id and agent_uid == ^agent_uid) |> one()

  @doc "Reads one call of a run without a lock, or `nil`."
  def get_call(call_id, run_id, agent_uid) do
    AgentCall
    |> Ash.Query.filter(id == ^call_id and run_id == ^run_id and agent_uid == ^agent_uid)
    |> one()
  end

  def lock_run(run_id) do
    Run
    |> Ash.Query.filter(id == ^run_id)
    |> Ash.Query.lock(:for_update)
    |> one(lock_identity: {"workflow_runs", run_id})
  end

  def lock_run(run_id, agent_uid) do
    Run
    |> Ash.Query.filter(id == ^run_id and agent_uid == ^agent_uid)
    |> Ash.Query.lock(:for_update)
    |> one(lock_identity: {"workflow_runs", run_id})
  end

  def lock_call(call_id, run_id, agent_uid) do
    AgentCall
    |> Ash.Query.filter(id == ^call_id and run_id == ^run_id and agent_uid == ^agent_uid)
    |> Ash.Query.lock(:for_update)
    |> one(lock_identity: {"workflow_agent_calls", call_id})
  end

  def lock_run_calls(run_id) do
    AgentCall
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.sort(id: :asc)
    |> lock_calls()
  end

  def lock_run_calls_by_sequence(run_id) do
    AgentCall
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.sort(call_seq: :asc)
    |> lock_calls()
  end

  @doc "Locks the calls that a query selects, in the query order."
  def lock_calls(query) do
    {:ok, calls} =
      query
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read(lock_identity: {:rows, "workflow_agent_calls", :id})

    calls
  end

  defp one(query, opts \\ []) do
    {:ok, record} = Ankole.Ash.read_one(query, opts)
    record
  end
end
