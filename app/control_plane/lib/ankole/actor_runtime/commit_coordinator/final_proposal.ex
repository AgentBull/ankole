defmodule Ankole.ActorRuntime.CommitCoordinator.FinalProposal do
  @moduledoc false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.ActorRuntime.CommitCoordinator.Consumptions
  alias Ankole.ActorRuntime.CommitCoordinator.Deliveries
  alias Ankole.ActorRuntime.CommitCoordinator.Fences
  alias Ankole.ActorRuntime.CommitCoordinator.Messages
  alias Ankole.ActorRuntime.CommitCoordinator.TurnResult
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation

  def commit_in_tx(
        _repo,
        %LlmTurn{status: "succeeded"} = llm_turn,
        _turn_ref,
        _proposal,
        _now
      ) do
    {:ok, %{status: :already_committed, llm_turn: llm_turn}}
  end

  def commit_in_tx(repo, %LlmTurn{} = llm_turn, turn_ref, proposal, now) do
    with :ok <- Fences.require_turn_started(llm_turn),
         %Conversation{} = conversation <-
           AIAgent.lock_conversation(repo, llm_turn.conversation_id),
         :ok <- Fences.conversation_matches_turn(conversation, llm_turn),
         %ActorSessionActivation{} = activation <- Fences.activation_for_turn_ref(repo, turn_ref),
         :ok <- Fences.activation_accepts_turn(activation, turn_ref, llm_turn, now),
         {:ok, deliveries} <- Deliveries.accepted(repo, turn_ref),
         {:ok, actor_inputs} <- Deliveries.lock_actor_inputs(repo, deliveries),
         {:ok, proposed_messages} <-
           Messages.insert_proposed_runtime_messages(repo, conversation, llm_turn, proposal, now),
         {:ok, assistant_message} <-
           Messages.maybe_insert_assistant_message(
             repo,
             conversation,
             llm_turn,
             proposal,
             actor_inputs,
             now
           ),
         {:ok, llm_turn} <-
           TurnResult.mark_succeeded(
             repo,
             llm_turn,
             proposal,
             assistant_message,
             proposed_messages,
             now
           ),
         {:ok, consumptions} <-
           Consumptions.consume_actor_inputs(
             repo,
             actor_inputs,
             conversation,
             llm_turn,
             activation,
             assistant_message,
             now
           ),
         {_, _} <- Deliveries.delete(repo, actor_inputs),
         {:ok, conversation} <-
           AIAgent.clear_generation_in_tx(repo, conversation, llm_turn.lease_id) do
      {:ok,
       %{
         status: commit_status(llm_turn, actor_inputs, assistant_message),
         conversation: conversation,
         llm_turn: llm_turn,
         assistant_message: assistant_message,
         proposed_messages: proposed_messages,
         consumptions: consumptions
       }}
    else
      nil -> {:error, :actor_runtime_fence_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp commit_status(llm_turn, actor_inputs, nil) do
    case Messages.ambient_silence_allowed?(actor_inputs) do
      true ->
        :ambient_silent

      false ->
        case Messages.schedule_turn_silence_allowed?(llm_turn, actor_inputs) do
          true -> :schedule_silent
          false -> :committed
        end
    end
  end

  defp commit_status(_llm_turn, _actor_inputs, %Message{}), do: :committed
end
