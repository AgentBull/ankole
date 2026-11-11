defmodule Ankole.Pod.RunnerJobs do
  @moduledoc "Starts a device-backed Job from the user's private native conversation."

  alias Ankole.{ActorRef, AgentWorkers, AuthZ, BackgroundAgentJobs, Conversations}
  alias Ankole.AuthZ.Actor
  alias Ankole.Sessions.Key

  def create(%Actor{} = actor, args) do
    uid = Actor.uid(actor)

    with {:ok, %{created_by: ^uid, native_access_scope: :participants} = conversation} <-
           Conversations.visible_native_conversation(actor, args.id),
         %{role: :agent} <- Conversations.get_participant!(conversation.id, args.agentUID),
         {:ok, [true]} <-
           AuthZ.authorize_checks(
             actor,
             [%{resource: "agent:#{args.agentUID}", action: "chat"}],
             Actor.request_context(actor)
           ),
         :ok <- AgentWorkers.authorize_runner_for_job(actor, args.agentUID, args.runnerID),
         {:ok, %{job: job}} <-
           BackgroundAgentJobs.create_with_dispatch(%{
             "agent_uid" => args.agentUID,
             "runner_id" => args.runnerID,
             "title" => args.title,
             "task" => args.task,
             "owner_session_id" => Key.conversation(conversation.id),
             "source_tool_call_id" => "pod-runner:" <> args.requestID,
             "created_by" => %{"principal_uid" => to_string(ActorRef.from_actor(actor))},
             "reply_route" => %{"conversation_id" => conversation.id}
           }) do
      {:ok, %{jobID: job.id}}
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end
end
