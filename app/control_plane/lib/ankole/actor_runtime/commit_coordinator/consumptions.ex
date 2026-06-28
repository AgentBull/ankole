defmodule Ankole.ActorRuntime.CommitCoordinator.Consumptions do
  @moduledoc false

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.CommitCoordinator.Payload
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway

  def consume_actor_inputs(
        repo,
        actor_inputs,
        %Conversation{} = conversation,
        %LlmTurn{} = llm_turn,
        %ActorSessionActivation{} = activation,
        assistant_message,
        now
      ) do
    ambient_post_input_id = ambient_post_input_id(actor_inputs, assistant_message)

    outbox_scope = %{
      ambient_post_input_id: ambient_post_input_id,
      visible_reply_input_id:
        visible_reply_input_id(actor_inputs, assistant_message, ambient_post_input_id)
    }

    actor_inputs
    |> Enum.map(fn actor_input ->
      Actors.consume_actor_input_in_tx(repo, actor_input,
        conversation_id: conversation.id,
        llm_turn_id: llm_turn.id,
        activation_uid: activation.activation_uid,
        actor_epoch: activation.actor_epoch,
        revision: activation.revision,
        consumed_at: now,
        outbox_intents:
          outbox_intents(repo, actor_input, llm_turn, assistant_message, outbox_scope)
      )
    end)
    |> Payload.collect_results()
  end

  def consume_summary_actor_inputs(
        repo,
        actor_inputs,
        %Conversation{} = conversation,
        %LlmTurn{} = llm_turn,
        %ActorSessionActivation{} = activation,
        %Message{} = summary_message,
        now
      ) do
    visible_reply_input_id = visible_reply_input_id(actor_inputs, summary_message, nil)

    actor_inputs
    |> Enum.map(fn actor_input ->
      Actors.consume_actor_input_in_tx(repo, actor_input,
        conversation_id: conversation.id,
        llm_turn_id: llm_turn.id,
        activation_uid: activation.activation_uid,
        actor_epoch: activation.actor_epoch,
        revision: activation.revision,
        consumed_at: now,
        outbox_intents:
          summary_outbox_intents(
            repo,
            actor_input,
            llm_turn,
            summary_message,
            visible_reply_input_id
          )
      )
    end)
    |> Payload.collect_results()
  end

  defp summary_outbox_intents(_repo, %ActorInput{signal_channel_id: nil}, _turn, _message, _id),
    do: []

  defp summary_outbox_intents(_repo, %ActorInput{provider_entry_id: nil}, _turn, _message, _id),
    do: []

  defp summary_outbox_intents(
         _repo,
         %ActorInput{id: id},
         _turn,
         _message,
         visible_reply_input_id
       )
       when id != visible_reply_input_id,
       do: []

  defp summary_outbox_intents(
         repo,
         %ActorInput{} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = summary_message,
         _visible_reply_input_id
       ) do
    operation = SignalsGateway.outbox_operation_for_actor_input(actor_input, repo)
    operation_key = Atom.to_string(operation)
    text = "Conversation compressed."

    [
      %{
        outbound_key: "summary:#{llm_turn.id}:#{operation_key}:#{actor_input.id}",
        operation: operation,
        target_provider_entry_id: actor_input.provider_entry_id,
        provider_thread_id: actor_input.provider_thread_id,
        payload: %{"text" => text},
        fallback_visible_text: text,
        idempotency_key: "summary:#{operation_key}:#{llm_turn.id}:#{actor_input.id}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: summary_message.id
      }
    ]
  end

  defp ambient_post_input_id(actor_inputs, %Message{}) do
    case Enum.find(actor_inputs, &(&1.type == "im.message.may_intervene")) do
      %ActorInput{id: id} -> id
      nil -> nil
    end
  end

  defp ambient_post_input_id(_actor_inputs, _assistant_message), do: nil

  defp visible_reply_input_id(_actor_inputs, nil, _ambient_post_input_id), do: nil

  defp visible_reply_input_id(_actor_inputs, %Message{}, ambient_post_input_id)
       when is_binary(ambient_post_input_id),
       do: nil

  defp visible_reply_input_id(actor_inputs, %Message{}, nil) do
    actor_inputs
    |> Enum.filter(&provider_visible_reply_input?/1)
    |> Enum.max_by(&reply_target_sort_key/1, fn -> nil end)
    |> case do
      %ActorInput{id: id} -> id
      nil -> nil
    end
  end

  defp provider_visible_reply_input?(%ActorInput{
         type: "im.message.may_intervene"
       }),
       do: false

  defp provider_visible_reply_input?(%ActorInput{
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id
       })
       when is_binary(signal_channel_id) and is_binary(provider_entry_id),
       do: true

  defp provider_visible_reply_input?(_actor_input), do: false

  defp reply_target_sort_key(%ActorInput{} = actor_input) do
    {
      provider_time_sort_value(actor_input),
      datetime_sort_value(actor_input.available_at),
      actor_input.live_queue_sequence || 0,
      actor_input.provider_entry_id || ""
    }
  end

  defp provider_time_sort_value(%ActorInput{payload: payload}) when is_map(payload) do
    payload
    |> get_in(["data", "entry", "provider_time"])
    |> datetime_iso8601_sort_value()
  end

  defp provider_time_sort_value(_actor_input), do: 0

  defp datetime_iso8601_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime_sort_value(datetime)
      _error -> 0
    end
  end

  defp datetime_iso8601_sort_value(_value), do: 0

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_value(_value), do: 0

  defp outbox_intents(_repo, _actor_input, _llm_turn, nil, _outbox_scope), do: []

  defp outbox_intents(
         _repo,
         %ActorInput{signal_channel_id: nil},
         _llm_turn,
         _assistant_message,
         _outbox_scope
       ),
       do: []

  defp outbox_intents(
         _repo,
         %ActorInput{type: "im.message.may_intervene", id: id} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = assistant_message,
         %{ambient_post_input_id: id}
       ) do
    [
      %{
        outbound_key: "ambient:#{llm_turn.id}:#{actor_input.signal_channel_id}",
        operation: :post,
        target_provider_entry_id: nil,
        provider_thread_id: actor_input.provider_thread_id,
        payload: assistant_outbox_payload(assistant_message),
        fallback_visible_text: assistant_text(assistant_message),
        idempotency_key: "post:ambient:#{llm_turn.id}:#{actor_input.signal_channel_id}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: assistant_message.id
      }
    ]
  end

  defp outbox_intents(
         _repo,
         %ActorInput{type: "im.message.may_intervene"},
         _llm_turn,
         _assistant_message,
         _outbox_scope
       ),
       do: []

  defp outbox_intents(
         _repo,
         %ActorInput{type: "cron.fire"} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = assistant_message,
         _outbox_scope
       ) do
    [
      %{
        outbound_key: "cron:#{llm_turn.id}:post:#{actor_input.id}",
        operation: :post,
        target_provider_entry_id: nil,
        provider_thread_id: actor_input.provider_thread_id,
        payload: assistant_outbox_payload(assistant_message),
        fallback_visible_text: assistant_text(assistant_message),
        idempotency_key: "post:cron:#{llm_turn.id}:#{actor_input.id}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: assistant_message.id
      }
    ]
  end

  defp outbox_intents(
         _repo,
         %ActorInput{provider_entry_id: nil},
         _llm_turn,
         _assistant_message,
         _outbox_scope
       ),
       do: []

  defp outbox_intents(
         _repo,
         %ActorInput{type: "command.steer"},
         _llm_turn,
         _assistant_message,
         _outbox_scope
       ),
       do: []

  defp outbox_intents(
         _repo,
         %ActorInput{id: id},
         _llm_turn,
         _assistant_message,
         %{visible_reply_input_id: visible_reply_input_id}
       )
       when id != visible_reply_input_id,
       do: []

  defp outbox_intents(
         repo,
         %ActorInput{} = actor_input,
         %LlmTurn{} = llm_turn,
         %Message{} = assistant_message,
         _outbox_scope
       ) do
    operation = SignalsGateway.outbox_operation_for_actor_input(actor_input, repo)
    operation_key = Atom.to_string(operation)

    [
      %{
        outbound_key: "llm-turn:#{llm_turn.id}:#{operation_key}:#{actor_input.id}",
        operation: operation,
        target_provider_entry_id: actor_input.provider_entry_id,
        provider_thread_id: actor_input.provider_thread_id,
        payload: assistant_outbox_payload(assistant_message),
        fallback_visible_text: assistant_text(assistant_message),
        idempotency_key: "#{operation_key}:#{llm_turn.id}:#{actor_input.id}",
        llm_turn_id: llm_turn.id,
        assistant_message_id: assistant_message.id
      }
    ]
  end

  defp assistant_outbox_payload(%Message{} = message) do
    %{"text" => assistant_text(message)}
    |> maybe_put("attachments", assistant_attachments(message))
  end

  defp assistant_attachments(%Message{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "attachment"} = attachment -> [Map.delete(attachment, "type")]
      _part -> []
    end)
  end

  defp assistant_attachments(_message), do: []

  defp assistant_text(%Message{content: [%{"text" => text} | _]}) when is_binary(text), do: text
  defp assistant_text(_message), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
