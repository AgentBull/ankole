defmodule Ankole.Workflow.ToolAdmission do
  @moduledoc "Prepares work locks before a tool receipt locks its participating Sessions."
  import Ecto.Query
  alias Ankole.Conversations.Route
  alias Ankole.Sessions.Run, as: SessionRun
  alias Ankole.Workflow.Lifecycle
  alias Ankole.Workflow.Mail
  alias Ankole.Workflow.Queries
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  alias Ankole.Workflow.Slot
  alias Ankole.Workflow.TaskLifecycle

  def prepare_in_tx(_repo, source, %{"name" => "workflow"} = tool_call, args) do
    attrs =
      args
      |> Map.take(~w(title script args concurrency max_agent_calls model_profile))
      |> Map.put("title", String.trim(args["title"]))
      |> Map.merge(%{
        "agent_uid" => source.agent_uid,
        "owner_session_id" => source.session_id,
        "source_signal_id" => source.signal_id,
        "source_tool_call_id" => SessionRun.tool_identity(source, tool_call),
        "reply_route" => Route.snapshot(source)
      })

    with {:ok, value} <- Lifecycle.create_with_dispatch(attrs) do
      {:ok, source_sessions(source), fn -> {:ok, value} end}
    end
  end

  def prepare_in_tx(repo, source, %{"name" => "send_message_to_workflow_task"} = tool_call, args) do
    with :ok <- Slot.lock_agent_slots(repo, source.agent_uid),
         %Run{} = run <- Slot.lock_run(repo, args["run_id"], source.agent_uid),
         %AgentCall{} = snapshot <-
           repo.one(
             from call in AgentCall,
               where: call.run_id == ^run.id and call.call_seq == ^args["call_seq"]
           ),
         %AgentCall{} = call <- Slot.lock_call(repo, snapshot.id, run.id, source.agent_uid) do
      sessions = work_sessions(source, run, [call])

      {:ok, sessions,
       fn ->
         Mail.send_task_message(
           run.id,
           call.call_seq,
           source.agent_uid,
           args["message"],
           SessionRun.tool_identity(source, tool_call)
         )
       end}
    else
      nil -> {:error, :workflow_task_not_found}
      error -> error
    end
  end

  def prepare_in_tx(repo, source, %{"name" => "cancel_workflow"}, args) do
    with :ok <- Slot.lock_agent_slots(repo, source.agent_uid),
         %Run{} = run <- Slot.lock_run(repo, args["run_id"], source.agent_uid) do
      calls = Slot.lock_run_calls(repo, run.id)

      {:ok, work_sessions(source, run, calls),
       fn -> Lifecycle.cancel_in_tx(repo, run.id, source.agent_uid) end}
    else
      nil -> {:error, :workflow_not_found}
      error -> error
    end
  end

  def prepare_in_tx(repo, source, %{"name" => "submit_result"}, args) do
    with {:ok, %{run: run, call: call}} <-
           Slot.lock_session_work_in_tx(repo, source.agent_uid, source.session_id),
         true <-
           call.id == source.spec.request_context["call_id"] ||
             {:error, :workflow_task_session_mismatch} do
      {:ok, work_sessions(source, run, [call]),
       fn ->
         TaskLifecycle.submit_result_in_tx(repo, call.id, source.agent_uid, source.session_id, %{
           "ok" => true,
           "value" => args["result"]
         })
       end}
    end
  end

  def prepare_in_tx(repo, source, %{"name" => "sleep"}, args) do
    with {:ok, %{run: run, call: call}} <-
           Slot.lock_session_work_in_tx(repo, source.agent_uid, source.session_id),
         true <-
           call.id == source.spec.request_context["call_id"] ||
             {:error, :workflow_task_session_mismatch} do
      {:ok, work_sessions(source, run, [call]),
       fn ->
         TaskLifecycle.sleep_task_in_tx(repo, call.id, source.agent_uid, source.session_id, %{
           wake_after_ms: args["wake_after_ms"],
           note: args["note"],
           attention: args["attention"] == true
         })
       end}
    end
  end

  defp source_sessions(source), do: [{source.agent_uid, source.session_id}]

  defp work_sessions(source, run, calls) do
    Enum.uniq(
      source_sessions(source) ++
        [{run.agent_uid, run.owner_session_id}] ++
        Enum.map(calls, &{&1.agent_uid, Queries.task_session_id(&1.id)})
    )
  end
end
