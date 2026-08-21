defmodule Ankole.Plugins.TelegramAdapter.ReplyPreview do
  @moduledoc "Crash-recoverable Telegram mutable reply lifecycle."

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

  alias Ankole.Plugins.TelegramAdapter.{Client, Config, ErrorPolicy, Outbox, Presentation}
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{ActorEvent, Actors, ReplyInteractionState, ReplyPresentation}
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  @checkpoint_version 1

  @impl true
  def open(%Request{} = request),
    do: request |> reconcile() |> ErrorPolicy.normalize_delivery_result()

  @impl true
  def update(%Request{} = request),
    do: request |> reconcile() |> ErrorPolicy.normalize_delivery_result()

  @impl true
  def finalize(%Request{} = request) do
    request
    |> Map.put(:mode, :terminal)
    |> reconcile()
    |> ErrorPolicy.normalize_delivery_result()
  end

  @impl true
  def refresh(%Request{} = request),
    do: request |> reconcile() |> ErrorPolicy.normalize_delivery_result()

  defp reconcile(%Request{} = request) do
    with {:ok, event} <- fresh_event(request.actor_event),
         {:ok, config} <- config_for_event(event),
         client <- Config.client(config),
         checkpoint <- current_checkpoint(event, request),
         presentation <-
           request.presentation
           |> ReplyPresentation.normalize()
           |> ReplyInteractionState.project(checkpoint),
         {:ok, chunks} <- Presentation.render(presentation, event.id),
         {:ok, channel} <- Outbox.parse_channel(event.signal_channel_id),
         {:ok, messages, responses} <-
           reconcile_messages(client, event, checkpoint, presentation, chunks, channel, request),
         first_id <- first_message_id(messages),
         :ok <-
           Actors.record_reply_preview_source_entry(event.id, first_id, event.signal_channel_id),
         checkpoint <- build_checkpoint(checkpoint, messages, presentation, request),
         {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok,
       %{
         created_source_entry_id: first_id,
         provider_thread_id: event.signal_channel_id,
         reply_preview_checkpoint: checkpoint,
         raw_payload: %{"messages" => responses},
         recovery_state: %{
           "message_id" => first_id,
           "messages" => messages,
           "streaming_state" => checkpoint["streaming_state"]
         }
       }
       |> maybe_put_payload(request.outbox)}
    end
  end

  defp reconcile_messages(client, event, checkpoint, presentation, chunks, channel, request) do
    existing = checkpoint |> message_records() |> Map.new(&{&1["index"], &1})

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, existing, [], false}, fn {chunk, index},
                                                        {:ok, records, responses, changed?} ->
      current = Map.get(records, index)

      case upsert_message(client, event, current, chunk, channel, index) do
        {:ok, message, response} ->
          records = Map.put(records, index, message)
          staged_messages = sorted_message_records(records)
          staged = build_checkpoint(checkpoint, staged_messages, presentation, request)

          case Actors.put_reply_preview_checkpoint(event.id, staged) do
            {:ok, _event} ->
              {:cont, {:ok, records, [response | responses], true}}

            {:error, _reason} = error ->
              {:halt, if(changed?, do: {:error, :telegram_partial_delivery}, else: error)}
          end

        {:error, :telegram_send_uncertain} ->
          {:halt, {:error, :telegram_send_uncertain}}

        {:error, _reason} when changed? ->
          {:halt, {:error, :telegram_partial_delivery}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records, responses, _changed?} ->
        messages =
          records
          |> Enum.filter(fn {index, _message} -> index < length(chunks) end)
          |> Map.new()
          |> sorted_message_records()

        with :ok <- delete_surplus_messages(client, event, existing, length(messages), channel) do
          {:ok, messages, Enum.reverse(responses)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp upsert_message(
         client,
         _event,
         %{"message_id" => message_id} = current,
         chunk,
         channel,
         index
       )
       when is_binary(message_id) do
    with {:ok, message_id} <- Outbox.integer_value(message_id) do
      body =
        %{
          "chat_id" => channel.chat_id,
          "message_id" => message_id,
          "text" => chunk["text"]
        }
        |> maybe_put("reply_markup", chunk["reply_markup"])

      case Client.call(client, "editMessageText", body) do
        {:ok, response} ->
          {:ok, Map.put(current, "index", index), compact_response(response)}

        {:error, %Client.Error{error_code: 400, description: description}}
        when is_binary(description) ->
          if String.contains?(String.downcase(description), "message is not modified") do
            {:ok, Map.put(current, "index", index),
             %{"message_id" => message_id, "not_modified" => true}}
          else
            if String.contains?(String.downcase(description), "message to edit not found") do
              post_message(client, nil, chunk, channel, index)
            else
              {:error, %Client.Error{kind: :api, error_code: 400, description: description}}
            end
          end

        {:error, %Client.Error{} = error} ->
          uncertain_or_error(error)
      end
    end
  end

  defp upsert_message(client, event, _missing, chunk, channel, index),
    do: post_message(client, event, chunk, channel, index)

  defp post_message(client, event, chunk, channel, index) do
    body =
      %{"chat_id" => channel.chat_id, "text" => chunk["text"]}
      |> maybe_put("message_thread_id", channel.topic_id)
      |> maybe_put("reply_markup", chunk["reply_markup"])
      |> maybe_reply(event)

    case Client.call(client, "sendMessage", body) do
      {:ok, %{"message_id" => message_id} = response} when is_integer(message_id) ->
        id = Integer.to_string(message_id)

        with :ok <- maybe_record_first_message(event, id) do
          {:ok, %{"index" => index, "message_id" => id}, compact_response(response)}
        end

      {:ok, _invalid} ->
        {:error, :telegram_message_id_missing}

      {:error, %Client.Error{} = error} ->
        uncertain_or_error(error)
    end
  end

  defp maybe_reply(body, %ActorEvent{} = event) do
    case ActorEvent.reply_anchor_source_entry_id(event) |> Outbox.integer_value() do
      {:ok, source_entry_id} ->
        Map.put(body, "reply_parameters", %{"message_id" => source_entry_id})

      {:error, _reason} ->
        body
    end
  end

  defp maybe_reply(body, _event), do: body

  defp maybe_record_first_message(%ActorEvent{reply_preview_source_entry_id: nil} = event, id),
    do: Actors.record_reply_preview_source_entry(event.id, id, event.signal_channel_id)

  defp maybe_record_first_message(_event, _id), do: :ok

  defp delete_surplus_messages(client, _event, existing, retained_count, channel) do
    existing
    |> Enum.filter(fn {index, _message} -> index >= retained_count end)
    |> Enum.reduce_while(:ok, fn {_index, %{"message_id" => message_id}}, :ok ->
      with {:ok, message_id} <- Outbox.integer_value(message_id) do
        case Client.call(client, "deleteMessage", %{
               "chat_id" => channel.chat_id,
               "message_id" => message_id
             }) do
          {:ok, _response} -> {:cont, :ok}
          {:error, %Client.Error{error_code: 400}} -> {:cont, :ok}
          {:error, %Client.Error{} = error} -> {:halt, uncertain_or_error(error)}
        end
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, :telegram_send_uncertain} -> {:error, :telegram_partial_delivery}
      other -> other
    end
  end

  defp build_checkpoint(checkpoint, messages, presentation, request) do
    previous = checkpoint["presentation"]
    terminal? = request.mode == :terminal or ReplyPresentation.terminal_state?(presentation)

    checkpoint
    |> Map.merge(%{
      "schema_version" => @checkpoint_version,
      "adapter" => "telegram",
      "subject_uid" => request.subject_uid || checkpoint["subject_uid"],
      "conversation_id" => request.conversation_id || checkpoint["conversation_id"],
      "message_id" => first_message_id(messages),
      "messages" => messages,
      "presentation" => ReplyPresentation.checkpoint(presentation),
      "streaming_state" => if(terminal?, do: "closed", else: "open")
    })
    |> put_previous_presentation(previous, presentation)
    |> Map.delete("refresh_pending")
    |> Map.delete("refresh_reason")
    |> Map.delete("recovery_state")
  end

  defp put_previous_presentation(checkpoint, previous, presentation) when is_map(previous) do
    if ReplyPresentation.normalize(previous) == ReplyPresentation.normalize(presentation) do
      Map.delete(checkpoint, "previous_presentation")
    else
      Map.put(checkpoint, "previous_presentation", ReplyPresentation.checkpoint(previous))
    end
  end

  defp put_previous_presentation(checkpoint, _previous, _presentation),
    do: Map.delete(checkpoint, "previous_presentation")

  defp message_records(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.filter(fn
      %{"index" => index, "message_id" => message_id}
      when is_integer(index) and is_binary(message_id) and message_id != "" ->
        true

      _invalid ->
        false
    end)
    |> Enum.sort_by(& &1["index"])
  end

  defp message_records(%{"message_id" => message_id}) when is_binary(message_id),
    do: [%{"index" => 0, "message_id" => message_id}]

  defp message_records(_checkpoint), do: []

  defp sorted_message_records(records) do
    records
    |> Map.values()
    |> Enum.sort_by(& &1["index"])
    |> Enum.with_index()
    |> Enum.map(fn {record, index} -> Map.put(record, "index", index) end)
  end

  defp first_message_id([%{"message_id" => message_id} | _rest]), do: message_id
  defp first_message_id(_messages), do: nil

  defp current_checkpoint(%ActorEvent{reply_preview_checkpoint: checkpoint}, _request)
       when is_map(checkpoint),
       do: checkpoint

  defp current_checkpoint(_event, %Request{checkpoint: checkpoint}) when is_map(checkpoint),
    do: checkpoint

  defp current_checkpoint(_event, _request), do: %{}

  defp config_for_event(%ActorEvent{} = event) do
    with {:ok, binding} <- SignalsGateway.get_binding(event.agent_uid, event.binding_name),
         {:ok, config} <- Config.load_config_ref(binding.config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp fresh_event(%ActorEvent{id: id}) do
    case Repo.get(ActorEvent, id) do
      %ActorEvent{} = event -> {:ok, event}
      nil -> {:error, :actor_event_not_found}
    end
  end

  defp uncertain_or_error(%Client.Error{kind: :transport}),
    do: {:error, :telegram_send_uncertain}

  defp uncertain_or_error(%Client.Error{error_code: code}) when is_integer(code) and code >= 500,
    do: {:error, :telegram_send_uncertain}

  defp uncertain_or_error(%Client.Error{} = error), do: {:error, error}

  defp compact_response(%{} = response),
    do: Map.take(response, ["message_id", "date", "edit_date"])

  defp compact_response(_response), do: %{}

  defp maybe_put_payload(result, %{} = outbox), do: Map.put(result, :payload, outbox.payload)
  defp maybe_put_payload(result, _outbox), do: result

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
