defmodule Ankole.Conversations.Delivery.Mirror do
  @moduledoc false

  alias Ankole.Signals.Signal
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.External
  alias Ankole.Conversations.Attachments

  def finalize_successful_intent(repo, intent, conversation, result, now) do
    with {:ok, sent} <- mark_intent_succeeded(repo, intent, result),
         {:ok, sent} <- mirror_intent_success(repo, sent, conversation, result, now),
         do: {:ok, sent}
  end

  defp mark_intent_succeeded(repo, intent, result) do
    recovery_state = result_map(result, :recovery_state, intent.recovery_state)
    payload = result_map(result, :payload, intent.payload)
    delivered_operation_attrs = delivered_operation_attrs(intent, result)

    with {:ok, recovery_state} <-
           JSONPayload.normalize_map(recovery_state, allow_datetime: true),
         {:ok, payload} <- JSONPayload.normalize_map(payload, allow_datetime: true) do
      Ankole.Ash.update(
        intent,
        :succeed,
        Map.merge(
          %{
            created_provider_message_id:
              created_provider_message_id_after_success(intent, result),
            provider_thread_id: provider_thread_id_after_success(intent, result),
            payload: payload,
            fallback_visible_text:
              result_text(result, :fallback_visible_text) || intent.fallback_visible_text,
            recovery_state: recovery_state
          },
          delivered_operation_attrs
        )
      )
      |> case do
        {:ok, succeeded} ->
          with :ok <-
                 Ankole.Conversations.Delivery.Recovery.notify_intent_deadline(repo, succeeded),
               do: {:ok, succeeded}

        error ->
          error
      end
    end
  end

  # An adapter may intentionally degrade a provider operation after a
  # deterministic rejection. Persist the operation that actually happened so
  # the intent audit row and the local provider mirror keep the same identity.
  defp delivered_operation_attrs(%Intent{operation: :edit}, result) do
    case Map.get(result, :delivered_operation) do
      :post ->
        %{
          operation: :post,
          target_provider_message_id: nil,
          reply_to_provider_message_id: nil
        }

      :reply ->
        %{
          operation: :reply,
          target_provider_message_id: nil,
          reply_to_provider_message_id: Map.get(result, :reply_to_provider_message_id)
        }

      _operation ->
        %{}
    end
  end

  defp delivered_operation_attrs(_intent, _result), do: %{}

  defp created_provider_message_id_after_success(%Intent{} = intent, result) do
    result_text(result, :created_provider_message_id) ||
      intent.created_provider_message_id
  end

  defp provider_thread_id_after_success(%Intent{} = intent, result) do
    result_text(result, :provider_thread_id) || intent.provider_thread_id
  end

  defp mirror_intent_success(
         repo,
         %Intent{operation: operation} = intent,
         _conversation,
         result,
         now
       )
       when operation in [:post, :reply, :divider, :card, :edit] do
    parts =
      case result do
        %{messages: messages} when is_list(messages) and messages != [] -> messages
        _ -> [result]
      end

    Enum.reduce_while(Enum.with_index(parts), {:ok, intent, nil}, fn {part, index},
                                                                     {:ok, current, first_id} ->
      case record_delivered_message(repo, current, part, index, now) do
        {:ok, message} -> {:cont, {:ok, current, first_id || message.id}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, current, first_id} ->
        Ankole.Ash.update(current, :link_message, %{created_message_id: first_id})

      {:error, _} = error ->
        error
    end
  end

  defp mirror_intent_success(
         repo,
         %Intent{operation: :delete} = intent,
         _conversation,
         _result,
         _now
       ) do
    with {:ok, _} <-
           External.remove_in_tx(repo, intent.conversation_id, intent.target_provider_message_id),
         do: {:ok, intent}
  end

  defp mirror_intent_success(
         repo,
         %Intent{operation: operation} = intent,
         _conversation,
         _result,
         now
       )
       when operation in [:reaction_add, :reaction_remove] do
    with {:ok, _} <-
           External.fold_reaction_in_tx(
             repo,
             intent.conversation_id,
             intent.target_provider_message_id,
             %{
               action: if(operation == :reaction_add, do: :add, else: :remove),
               reaction_key: intent.payload["reaction_key"],
               actor_key: intent.payload["actor_key"] || intent.agent_uid,
               raw_reaction_key: intent.payload["raw_reaction_key"]
             },
             now
           ),
         do: {:ok, intent}
  end

  defp record_delivered_message(repo, intent, result, index, now) do
    provider_id = delivered_provider_message_id(intent, result, index)

    if is_binary(provider_id) do
      prior = prior_delivery_observation(repo, intent.conversation_id, provider_id)
      text = delivered_message_text(result, intent)
      payload = result_map(result, :payload, intent.payload)

      observation = %{
        agent_uid: intent.agent_uid,
        provider_message_id: provider_id,
        reply_to_provider_message_id:
          intent.reply_to_provider_message_id || prior.external_ref.reply_to_provider_message_id,
        provider_thread_id:
          result_text(result, :provider_thread_id) || intent.provider_thread_id ||
            prior.external_ref.provider_thread_id,
        text: text,
        rich_content: Attachments.rich_content(text, json_map(payload, "formatted_content", %{})),
        attachments:
          if(intent.operation == :edit,
            do: prior.message.attachments,
            else: json_list(payload, "attachments")
          ),
        links: prior.message.links,
        mentions: prior.message.mentions,
        author: %{"agent_uid" => intent.agent_uid},
        metadata: Map.merge(prior.external_ref.metadata, json_map(payload, "metadata", %{})),
        raw_payload: result_map(result, :raw_payload, %{}),
        provider_time: result_datetime(result, :provider_time),
        ai_message_id: intent.ai_message_id,
        signal_id: intent.source_signal_id,
        session_id: delivery_source_session_id(repo, intent.source_signal_id)
      }

      with {:ok, %{message: message}} <-
             External.record_delivery_in_tx(repo, intent.conversation_id, observation, now),
           do: {:ok, message}
    else
      {:error, :delivery_provider_message_id_missing}
    end
  end

  defp delivered_provider_message_id(%Intent{operation: :edit} = intent, result, 0),
    do: intent.target_provider_message_id || result_text(result, :created_provider_message_id)

  defp delivered_provider_message_id(intent, result, _index),
    do: result_text(result, :created_provider_message_id) || intent.created_provider_message_id

  defp delivered_message_text(%{text: text}, _intent), do: text

  defp delivered_message_text(result, intent),
    do: result_text(result, :fallback_visible_text) || intent.fallback_visible_text

  defp prior_delivery_observation(repo, conversation_id, provider_message_id) do
    External.get_message(repo, conversation_id, provider_message_id) ||
      %{
        message: %{attachments: [], links: [], mentions: []},
        external_ref: %{
          reply_to_provider_message_id: nil,
          provider_thread_id: nil,
          metadata: %{}
        }
      }
  end

  defp delivery_source_session_id(_repo, nil), do: nil

  defp delivery_source_session_id(_repo, signal_id) do
    case Ankole.Signals.Domain.get_signal!(signal_id) do
      %Signal{session_id: session_id} -> session_id
      nil -> nil
    end
  end

  defp json_map(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp json_map(_map, _key, default), do: default

  defp json_list(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp json_list(_map, _key), do: []

  defp result_map(result, key, default) when is_map(result) and is_atom(key) do
    case Map.get(result, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp result_map(_result, _key, default), do: default

  defp result_datetime(result, key) when is_map(result) and is_atom(key) do
    case Map.get(result, key) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp result_datetime(_result, _key), do: nil

  defp result_text(result, key) when is_map(result) and is_atom(key),
    do: Ankole.Attrs.optional_text(Map.get(result, key))

  defp result_text(_result, _key), do: nil
end
