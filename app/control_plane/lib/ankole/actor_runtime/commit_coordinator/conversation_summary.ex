defmodule Ankole.ActorRuntime.CommitCoordinator.ConversationSummary do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.CommitCoordinator.Consumptions
  alias Ankole.ActorRuntime.CommitCoordinator.Deliveries
  alias Ankole.ActorRuntime.CommitCoordinator.Fences
  alias Ankole.ActorRuntime.CommitCoordinator.Messages
  alias Ankole.ActorRuntime.CommitCoordinator.Payload
  alias Ankole.ActorRuntime.CommitCoordinator.TurnResult
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation

  def commit_in_tx(
        _repo,
        %LlmTurn{status: "succeeded"} = llm_turn,
        _turn_ref,
        _request,
        _now
      ) do
    {:ok, %{status: :already_committed, llm_turn: llm_turn}}
  end

  def commit_in_tx(repo, %LlmTurn{} = llm_turn, turn_ref, request, now) do
    with {:ok, summary} <- request_summary(request),
         :ok <- Fences.require_turn_started(llm_turn),
         %Conversation{} = conversation <-
           AIAgent.lock_conversation(repo, llm_turn.conversation_id),
         :ok <- Fences.conversation_matches_turn(conversation, llm_turn),
         %ActorSessionActivation{} = activation <- Fences.activation_for_turn_ref(repo, turn_ref),
         :ok <- Fences.activation_accepts_turn(activation, turn_ref, llm_turn, now),
         {:ok, deliveries} <- Deliveries.accepted(repo, turn_ref),
         {:ok, actor_inputs} <- Deliveries.lock_actor_inputs(repo, deliveries),
         {:ok, summary_actor_inputs, deferred_actor_inputs} <-
           summary_commit_actor_inputs(actor_inputs),
         {:ok, summary_text} <- summary_text(summary),
         {:ok, covered_messages} <- summary_covered_messages(repo, conversation, summary),
         {:ok, summary_message} <-
           Messages.insert_summary_message(
             repo,
             conversation,
             llm_turn,
             summary_actor_inputs,
             covered_messages,
             summary_text,
             now
           ),
         {:ok, llm_turn} <-
           TurnResult.mark_succeeded(
             repo,
             llm_turn,
             summary_proposal(request, summary_text, covered_messages),
             summary_message,
             [],
             now
           ),
         {:ok, consumptions} <-
           Consumptions.consume_summary_actor_inputs(
             repo,
             summary_actor_inputs,
             conversation,
             llm_turn,
             activation,
             summary_message,
             now
           ),
         {_, _} <- Deliveries.delete(repo, summary_actor_inputs),
         {_, _} <- Deliveries.release_deferred_summary(repo, deferred_actor_inputs),
         {:ok, conversation} <-
           AIAgent.clear_generation_in_tx(repo, conversation, llm_turn.lease_id) do
      {:ok,
       %{
         status: :committed,
         conversation: conversation,
         llm_turn: llm_turn,
         summary_message: summary_message,
         covered_message_ids: Enum.map(covered_messages, & &1.id),
         consumptions: consumptions
       }}
    else
      nil -> {:error, :actor_runtime_fence_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp request_summary(request) do
    case Payload.fetch_map(request, "summary") do
      %{} = summary -> {:ok, summary}
      _value -> {:error, :summary_missing}
    end
  end

  defp summary_commit_actor_inputs(actor_inputs) do
    {deferred, summary_inputs} =
      Enum.split_with(actor_inputs, &defer_summary_actor_input?/1)

    case summary_inputs do
      [] -> {:error, :summary_actor_input_missing}
      [_ | _] -> {:ok, summary_inputs, deferred}
    end
  end

  defp defer_summary_actor_input?(%ActorInput{type: "command.steer"}), do: true
  defp defer_summary_actor_input?(%ActorInput{}), do: false

  defp summary_text(summary) when is_map(summary) do
    case Payload.fetch_text(summary, "text") do
      text when is_binary(text) ->
        case String.trim(text) do
          "" -> {:error, :summary_text_missing}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, :summary_text_missing}
    end
  end

  defp summary_covered_messages(repo, %Conversation{} = conversation, summary) do
    covered_message_ids =
      summary
      |> Payload.fetch_list("covered_message_ids")
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case covered_message_ids do
      [] ->
        {:error, :summary_covered_message_ids_missing}

      ids ->
        messages =
          Message
          |> where([message], message.conversation_id == ^conversation.id)
          |> where([message], message.status == "complete")
          |> where([message], message.id in ^ids)
          |> order_by([message], asc: message.inserted_at, asc: message.id)
          |> lock("FOR SHARE")
          |> repo.all()

        case MapSet.new(Enum.map(messages, & &1.id)) == MapSet.new(ids) do
          true -> {:ok, messages}
          false -> {:error, :summary_covered_message_not_found}
        end
    end
  end

  defp summary_proposal(request, text, covered_messages) do
    %{
      "summary" => %{
        "text" => text,
        "covered_message_ids" => Enum.map(covered_messages, & &1.id)
      },
      "usage_json" => Payload.fetch_map(request, "usage_json") || %{},
      "provider_metadata_json" => Payload.fetch_map(request, "provider_metadata_json") || %{}
    }
  end
end
