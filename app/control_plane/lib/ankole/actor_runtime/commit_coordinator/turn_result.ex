defmodule Ankole.ActorRuntime.CommitCoordinator.TurnResult do
  @moduledoc false

  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.ActorRuntime.CommitCoordinator.Messages
  alias Ankole.ActorRuntime.CommitCoordinator.Payload

  def mark_succeeded(
        repo,
        llm_turn,
        proposal,
        assistant_message,
        proposed_messages,
        now
      ) do
    response =
      %{
        "proposal" => Payload.proposal_summary(proposal),
        "proposed_message_ids" => Enum.map(proposed_messages, & &1.id)
      }
      |> maybe_put_stop_reason(proposal)
      |> maybe_put_assistant_message_id(assistant_message)
      |> maybe_put_silent_success(proposal, assistant_message)

    attrs = %{
      status: "succeeded",
      response: response,
      completed_at: now,
      usage: Payload.proposal_usage(proposal, llm_turn),
      tool_results: Payload.proposal_tool_results(proposal),
      provider_metadata: Payload.proposal_provider_metadata(proposal, llm_turn)
    }

    llm_turn
    |> LlmTurn.changeset(attrs)
    |> repo.update()
  end

  defp maybe_put_assistant_message_id(response, %Message{id: id}),
    do: Map.put(response, "assistant_message_id", id)

  defp maybe_put_assistant_message_id(response, nil), do: response

  defp maybe_put_silent_success(response, proposal, nil) do
    case Messages.silent_success_requested?(proposal) do
      true -> Map.put(response, "silent_success", true)
      false -> response
    end
  end

  defp maybe_put_silent_success(response, _proposal, %Message{}), do: response

  defp maybe_put_stop_reason(response, proposal) do
    case Payload.fetch_text(proposal, "stop_reason") do
      value when is_binary(value) and value != "" -> Map.put(response, "stop_reason", value)
      _value -> response
    end
  end
end
