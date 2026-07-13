defmodule Ankole.Brain.RuntimeContext do
  @moduledoc """
  Resolves the durable Brain conversation and scope for one fenced worker turn.

  Root turns use their active AIGateway conversation. Subagent turns use the
  parent conversation recorded by the delegation, so they inherit the exact
  same library routing and frozen snapshot without trusting RPC payload hints.
  """

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Brain.Scope
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @type t :: %{
          required(:conversation) => Conversation.t(),
          required(:scope) => Scope.t(),
          optional(:delegation) => Delegation.t()
        }

  @spec resolve(TurnRef.t()) :: {:ok, t()} | {:error, term()}
  def resolve(%TurnRef{session_id: "subagent:" <> delegation_id} = turn_ref) do
    with %Delegation{} = delegation <-
           Repo.get_by(Delegation, id: delegation_id, agent_uid: turn_ref.agent_uid),
         conversation_id when is_binary(conversation_id) <-
           Map.get(delegation.metadata || %{}, "brain_parent_conversation_id"),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation, id: conversation_id, subject_uid: turn_ref.agent_uid),
         {:ok, scope} <- Scope.from_conversation(conversation) do
      {:ok, %{conversation: conversation, scope: scope, delegation: delegation}}
    else
      nil -> {:error, :brain_parent_conversation_not_found}
      {:error, _reason} = error -> error
      _missing_id -> {:error, :brain_parent_conversation_not_found}
    end
  end

  def resolve(%TurnRef{} = turn_ref) do
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
