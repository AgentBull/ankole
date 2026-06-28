defmodule Ankole.ActorRuntime.CommitCoordinator.Messages do
  @moduledoc false

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.ActorRuntime.CommitCoordinator.Payload

  # Roles a worker may write as extra transcript rows in its proposal. Notably
  # `assistant` is excluded: the visible answer must come only from `reply`.
  @runtime_proposal_roles ~w(user tool im_ambient)

  def insert_proposed_runtime_messages(repo, conversation, llm_turn, proposal, now) do
    proposal
    |> Payload.fetch_list("messages")
    |> Enum.with_index()
    |> Enum.flat_map(fn {message, index} ->
      case proposed_runtime_message_attrs(conversation, llm_turn, message, index, now) do
        {:ok, attrs} -> [%Message{} |> Message.changeset(attrs) |> repo.insert()]
        :skip -> []
      end
    end)
    |> Payload.collect_results()
  end

  def insert_summary_message(
        repo,
        %Conversation{} = conversation,
        %LlmTurn{} = llm_turn,
        actor_inputs,
        covered_messages,
        text,
        now
      ) do
    attrs = %{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: "assistant",
      kind: "summary",
      status: "complete",
      content: [%{"type" => "text", "text" => text}],
      event_source: "agent_computer.conversation_summary",
      event_id: llm_turn.id,
      covers_range: summary_covers_range(covered_messages),
      metadata: %{
        "actor_input_ids" => Enum.map(actor_inputs, & &1.id),
        "committed_at" => DateTime.to_iso8601(now),
        "compression" => %{
          "trigger" => "worker_command",
          "llm_turn_ids" => [llm_turn.id],
          "covered_message_ids" => Enum.map(covered_messages, & &1.id),
          "strategy" => "worker_owned"
        }
      }
    }

    %Message{}
    |> Message.changeset(attrs)
    |> repo.insert()
  end

  def maybe_insert_assistant_message(repo, conversation, llm_turn, proposal, actor_inputs, now) do
    case {ambient_silence_allowed?(actor_inputs),
          schedule_silent_success_allowed?(proposal, llm_turn, actor_inputs),
          Payload.fetch_map(proposal, "reply")} do
      {true, _schedule, nil} ->
        {:ok, nil}

      {_ambient, true, nil} ->
        {:ok, nil}

      _other ->
        maybe_insert_visible_assistant_message(
          repo,
          conversation,
          llm_turn,
          proposal,
          actor_inputs,
          now
        )
    end
  end

  def ambient_silence_allowed?(actor_inputs) do
    actor_inputs != [] and Enum.all?(actor_inputs, &(&1.type == "im.message.may_intervene"))
  end

  def schedule_silent_success_allowed?(proposal, %LlmTurn{} = llm_turn, actor_inputs) do
    silent_success_requested?(proposal) and schedule_turn_silence_allowed?(llm_turn, actor_inputs)
  end

  def silent_success_requested?(proposal) when is_map(proposal) do
    Payload.fetch_value(proposal, "silent_success") == true or
      get_in(Payload.fetch_map(proposal, "metadata_json") || %{}, ["silent_success"]) == true or
      get_in(Payload.fetch_map(proposal, "response_json") || %{}, ["silent_success"]) == true
  end

  def schedule_turn_silence_allowed?(%LlmTurn{request_context: context}, actor_inputs)
      when is_map(context) do
    context["silent_success_allowed"] == true and actor_inputs != [] and
      Enum.all?(actor_inputs, &(&1.type in ["check_back_later.wakeup", "cron.fire"]))
  end

  def schedule_turn_silence_allowed?(_llm_turn, _actor_inputs), do: false

  defp proposed_runtime_message_attrs(conversation, llm_turn, proposed, index, now)
       when is_map(proposed) do
    role = Payload.fetch_text(proposed, "role")

    if role in @runtime_proposal_roles do
      metadata = Payload.fetch_map(proposed, "metadata_json") || %{}

      kind =
        Payload.fetch_text(metadata, "kind") || Payload.fetch_text(metadata, "message_kind") ||
          "normal"

      {:ok,
       %{
         agent_uid: conversation.agent_uid,
         conversation_id: conversation.id,
         role: role,
         kind: kind,
         status: "complete",
         content: proposed_content(proposed),
         event_source: Payload.fetch_text(metadata, "event_source") || "agent_computer.proposal",
         event_id: Payload.fetch_text(metadata, "event_id") || "#{llm_turn.id}:#{index}",
         metadata:
           metadata
           |> Map.put_new("llm_turn_id", llm_turn.id)
           |> Map.put_new("committed_at", DateTime.to_iso8601(now))
       }}
    else
      :skip
    end
  end

  defp proposed_runtime_message_attrs(_conversation, _llm_turn, _proposed, _index, _now),
    do: :skip

  defp proposed_content(proposed) do
    case Payload.fetch_value(proposed, "content_json") do
      value when is_list(value) -> value
      value when is_binary(value) -> [%{"type" => "text", "text" => value}]
      _value -> []
    end
  end

  defp summary_covers_range([first | _] = messages) do
    message_ids = Enum.map(messages, & &1.id)

    %{
      "first_message_id" => first.id,
      "last_message_id" => List.last(message_ids),
      "message_ids" => message_ids,
      "message_count" => length(message_ids)
    }
  end

  defp insert_assistant_message(repo, conversation, llm_turn, proposal, actor_inputs, now) do
    with {:ok, text} <- Payload.proposal_reply_text(proposal, llm_turn),
         {:ok, attachments} <- Payload.proposal_reply_attachments(proposal) do
      attrs = %{
        agent_uid: conversation.agent_uid,
        conversation_id: conversation.id,
        role: "assistant",
        kind: "normal",
        status: "complete",
        content: Payload.assistant_content(text, attachments),
        metadata: %{
          "actor_input_ids" => Enum.map(actor_inputs, & &1.id),
          "committed_at" => DateTime.to_iso8601(now)
        }
      }

      %Message{}
      |> Message.changeset(attrs)
      |> repo.insert()
    end
  end

  defp maybe_insert_visible_assistant_message(
         repo,
         conversation,
         llm_turn,
         proposal,
         actor_inputs,
         now
       ) do
    case Payload.proposal_reply_text(proposal, llm_turn) do
      {:ok, _text} ->
        insert_assistant_message(repo, conversation, llm_turn, proposal, actor_inputs, now)

      {:error, reason} when reason in [:proposal_reply_missing, :proposal_reply_text_missing] ->
        case ambient_silence_allowed?(actor_inputs) or
               schedule_silent_success_allowed?(proposal, llm_turn, actor_inputs) do
          true -> {:ok, nil}
          false -> {:error, reason}
        end
    end
  end
end
