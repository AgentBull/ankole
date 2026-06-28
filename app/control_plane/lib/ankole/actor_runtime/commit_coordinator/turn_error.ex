defmodule Ankole.ActorRuntime.CommitCoordinator.TurnError do
  @moduledoc false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.ActorRuntime.CommitCoordinator.Deliveries
  alias Ankole.ActorRuntime.CommitCoordinator.Fences
  alias Ankole.ActorRuntime.CommitCoordinator.Payload
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation

  def handle_in_tx(repo, %LlmTurn{} = llm_turn, turn_ref, payload, now) do
    reason = Payload.worker_turn_error(payload)

    with :ok <- Fences.require_turn_started(llm_turn),
         %Conversation{} = conversation <-
           AIAgent.lock_conversation(repo, llm_turn.conversation_id),
         %ActorSessionActivation{} = activation <- Fences.activation_for_turn_ref(repo, turn_ref),
         :ok <- Fences.activation_matches_turn(activation, turn_ref, llm_turn),
         {:ok, failed_turn} <-
           AIAgent.fail_turn_in_tx(repo, llm_turn, reason, now),
         {:ok, conversation} <-
           AIAgent.clear_generation_in_tx(repo, conversation, failed_turn.lease_id),
         {superseded_count, _rows} <-
           Deliveries.supersede_turn(repo, turn_ref, now, reason),
         {:ok, activation} <- fail_activation(repo, activation, reason, now) do
      {:ok,
       %{
         status: :turn_failed,
         conversation: conversation,
         llm_turn: failed_turn,
         activation: activation,
         superseded_deliveries: superseded_count
       }}
    else
      nil -> {:error, :actor_runtime_fence_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp fail_activation(repo, %ActorSessionActivation{} = activation, reason, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "failed",
      current_llm_turn_id: nil,
      stopped_at: now,
      stop_reason: inspect(reason)
    })
    |> repo.update()
  end
end
