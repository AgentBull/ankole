defmodule Ankole.Brain.RuntimeContext do
  @moduledoc """
  Resolves the durable Brain conversation and scope for one fenced worker turn.

  Root turns use their active AIGateway conversation. BackgroundAgentJob turns
  use the owner conversation recorded by the Job, so they inherit the exact
  same library routing and frozen snapshot without trusting RPC payload hints.
  """

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Brain.Scope
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @type t :: %{
          required(:conversation) => Conversation.t(),
          required(:scope) => Scope.t(),
          optional(:job) => Job.t()
        }

  @spec resolve(TurnRef.t()) :: {:ok, t()} | {:error, term()}
  def resolve(%TurnRef{} = turn_ref) do
    case BackgroundAgentJobs.parse_job_session_id(turn_ref.session_id) do
      {:ok, job_id} -> resolve_job_turn(turn_ref, job_id)
      :error -> resolve_conversation_turn(turn_ref)
    end
  end

  defp resolve_job_turn(%TurnRef{} = turn_ref, job_id) do
    with %Job{} = job <-
           Repo.get_by(Job, id: job_id, agent_uid: turn_ref.agent_uid),
         conversation_id when is_binary(conversation_id) <-
           Map.get(job.metadata || %{}, "brain_owner_conversation_id"),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation, id: conversation_id, subject_uid: turn_ref.agent_uid),
         {:ok, scope} <- Scope.from_conversation(conversation) do
      {:ok, %{conversation: conversation, scope: scope, job: job}}
    else
      nil -> {:error, :brain_owner_conversation_not_found}
      {:error, _reason} = error -> error
      _missing_id -> {:error, :brain_owner_conversation_not_found}
    end
  end

  defp resolve_conversation_turn(%TurnRef{} = turn_ref) do
    with %Conversation{} = conversation <-
           AIGatewayLink.active_conversation(turn_ref.agent_uid, turn_ref.session_id),
         {:ok, scope} <- Scope.from_conversation(conversation) do
      {:ok, %{conversation: conversation, scope: scope}}
    else
      nil -> {:error, :brain_conversation_not_found}
      {:error, _reason} = error -> error
    end
  end
end
