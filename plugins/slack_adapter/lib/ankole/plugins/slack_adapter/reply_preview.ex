defmodule Ankole.Plugins.SlackAdapter.ReplyPreview do
  @moduledoc """
  Crash-recoverable Slack Block Kit reply lifecycle.

  Slack owns the transport and rendering. One Agent reply is projected to one or
  more Slack messages and updated with `chat.update`. PostgreSQL stores the Slack
  message timestamps and the provider-neutral presentation, so a restart or a
  resolved interaction can repaint the same reply surface.
  """

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

  alias Ankole.Plugins.SlackAdapter.{BlockKit, Config, ErrorPolicy, Mrkdwn}
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias SlackOpenAPI.Error

  @checkpoint_version 1
  @fallback_chars 3_000

  @impl true
  def open(%Request{} = request), do: request |> reconcile() |> normalize_result()

  @impl true
  def update(%Request{} = request), do: request |> reconcile() |> normalize_result()

  @impl true
  def finalize(%Request{} = request),
    do: request |> Map.put(:mode, :terminal) |> reconcile() |> normalize_result()

  @impl true
  def refresh(%Request{} = request), do: request |> reconcile() |> normalize_result()

  defp reconcile(%Request{} = request) do
    with {:ok, event} <- fresh_event(request.actor_event),
         {:ok, config} <- config_for_event(event),
         client <- Config.client(config),
         checkpoint <- current_checkpoint(event, request),
         presentation <-
           request.presentation
           |> ReplyPresentation.normalize()
           |> ReplyInteractionState.project(checkpoint),
         {:ok, blocks} <- BlockKit.render(%{"reply_presentation" => presentation}),
         chunks <- normalized_chunks(blocks),
         {:ok, messages, responses} <-
           reconcile_messages(client, event, checkpoint, presentation, chunks, request),
         provider_thread_id <- response_thread_id(event, responses),
         :ok <-
           Actors.record_reply_preview_source_entry(
             event.id,
             first_message_id(messages),
             provider_thread_id
           ),
         checkpoint <- build_checkpoint(checkpoint, messages, presentation, request),
         {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok,
       %{
         created_source_entry_id: first_message_id(messages),
         provider_thread_id: provider_thread_id,
         reply_preview_checkpoint: checkpoint,
         raw_payload: %{"messages" => responses},
         recovery_state: %{
           "message_id" => first_message_id(messages),
           "messages" => messages,
           "streaming_state" => checkpoint["streaming_state"]
         }
       }
       |> maybe_put_payload(request.outbox)}
    end
  end

  defp reconcile_messages(client, event, checkpoint, presentation, chunks, request) do
    existing =
      checkpoint
      |> message_records()
      |> Map.new(&{&1["index"], &1})

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, existing, []}, fn {blocks, index}, {:ok, records, responses} ->
      current = Map.get(records, index)

      case upsert_message(client, event, current, blocks, presentation, index) do
        {:ok, message, response} ->
          records = Map.put(records, index, message)
          staged_messages = sorted_message_records(records)
          staged = build_checkpoint(checkpoint, staged_messages, presentation, request)

          case Actors.put_reply_preview_checkpoint(event.id, staged) do
            {:ok, _event} ->
              {:cont, {:ok, records, [response | responses]}}

            {:error, _reason} = error ->
              {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records, responses} ->
        messages =
          records
          |> Enum.filter(fn {index, _message} -> index < length(chunks) end)
          |> Map.new()
          |> sorted_message_records()

        with :ok <- delete_surplus_messages(client, event, existing, length(messages)) do
          {:ok, messages, Enum.reverse(responses)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp upsert_message(client, event, %{"message_id" => message_id}, blocks, presentation, index)
       when is_binary(message_id) do
    body = %{
      "channel" => channel_id(event.signal_channel_id),
      "ts" => message_id,
      "text" => fallback_text(presentation, index),
      "blocks" => blocks
    }

    case SlackOpenAPI.post(client, "chat.update", body: body) do
      {:ok, response} ->
        {:ok, message_record(index, message_id), response}

      {:error, %Error{reason: "message_not_found"}} ->
        post_message(client, event, blocks, presentation, index)

      {:error, _reason} = error ->
        error
    end
  end

  defp upsert_message(client, event, _missing, blocks, presentation, index),
    do: post_message(client, event, blocks, presentation, index)

  defp post_message(client, event, blocks, presentation, index) do
    body = %{
      "channel" => channel_id(event.signal_channel_id),
      "text" => fallback_text(presentation, index),
      "blocks" => blocks
    }

    body =
      case ActorEvent.reply_anchor_source_entry_id(event) do
        source_entry_id when is_binary(source_entry_id) ->
          Map.put(body, "thread_ts", source_entry_id)

        _no_anchor ->
          body
      end

    with {:ok, %{"ts" => message_id} = response} <- post_with_thread_fallback(client, body),
         :ok <- maybe_record_first_message(event, index, message_id, response) do
      {:ok, message_record(index, message_id), response}
    else
      {:ok, response} -> {:error, {:slack_message_id_missing, response}}
      {:error, _reason} = error -> error
    end
  end

  defp post_with_thread_fallback(client, body) do
    case SlackOpenAPI.post(client, "chat.postMessage", body: body) do
      {:error, %Error{reason: reason}}
      when reason in ["thread_not_found", "message_not_found"] and is_map_key(body, "thread_ts") ->
        SlackOpenAPI.post(client, "chat.postMessage", body: Map.delete(body, "thread_ts"))

      result ->
        result
    end
  end

  defp maybe_record_first_message(
         %ActorEvent{reply_preview_source_entry_id: nil} = event,
         0,
         id,
         response
       ),
       do:
         Actors.record_reply_preview_source_entry(
           event.id,
           id,
           response_thread_id(event, [response])
         )

  defp maybe_record_first_message(_event, _index, _id, _response), do: :ok

  defp response_thread_id(event, responses) do
    thread_ts =
      Enum.find_value(responses, fn response ->
        get_in(response, ["message", "thread_ts"])
      end)

    if is_binary(thread_ts), do: "#{event.signal_channel_id}:#{URI.encode(thread_ts)}"
  end

  defp delete_surplus_messages(client, event, existing, retained_count) do
    existing
    |> Enum.filter(fn {index, _message} -> index >= retained_count end)
    |> Enum.reduce_while(:ok, fn {_index, %{"message_id" => message_id}}, :ok ->
      body = %{"channel" => channel_id(event.signal_channel_id), "ts" => message_id}

      case SlackOpenAPI.post(client, "chat.delete", body: body) do
        {:ok, _response} -> {:cont, :ok}
        {:error, %Error{reason: "message_not_found"}} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp build_checkpoint(checkpoint, messages, presentation, request) do
    previous = checkpoint["presentation"]
    terminal? = request.mode == :terminal or ReplyPresentation.terminal_state?(presentation)

    checkpoint
    |> Map.merge(%{
      "schema_version" => @checkpoint_version,
      "adapter" => "slack",
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

  defp message_records(%{"message_id" => message_id})
       when is_binary(message_id) and message_id != "",
       do: [message_record(0, message_id)]

  defp message_records(_checkpoint), do: []

  defp message_record(index, message_id), do: %{"index" => index, "message_id" => message_id}

  defp sorted_message_records(records) do
    records
    |> Map.values()
    |> Enum.sort_by(& &1["index"])
  end

  defp normalized_chunks(blocks) do
    case BlockKit.split_blocks(blocks) do
      [] -> [[%{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => "（无内容）"}}]]
      chunks -> chunks
    end
  end

  defp fallback_text(presentation, index) do
    text =
      presentation
      |> ReplyPresentation.fallback_text()
      |> Mrkdwn.from_markdown()

    text = if index == 0, do: text, else: "#{text} (continued #{index + 1})"
    truncate(text, @fallback_chars)
  end

  defp current_checkpoint(%ActorEvent{reply_preview_checkpoint: checkpoint}, _request)
       when is_map(checkpoint),
       do: checkpoint

  defp current_checkpoint(_event, %Request{checkpoint: checkpoint}) when is_map(checkpoint),
    do: checkpoint

  defp current_checkpoint(_event, _request), do: %{}

  defp first_message_id([%{"message_id" => message_id} | _rest]), do: message_id
  defp first_message_id(_messages), do: nil

  defp maybe_put_payload(result, %{} = outbox), do: Map.put(result, :payload, outbox.payload)
  defp maybe_put_payload(result, _outbox), do: result

  defp config_for_event(%ActorEvent{} = event) do
    with {:ok, binding} <- SignalsGateway.get_binding(event.agent_uid, event.binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
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

  defp channel_id("slack:" <> encoded), do: URI.decode(encoded)
  defp channel_id(channel), do: channel

  defp truncate(text, size), do: text |> String.graphemes() |> Enum.take(size) |> Enum.join()

  defp normalize_result(result), do: ErrorPolicy.normalize_delivery_result(result)
end
