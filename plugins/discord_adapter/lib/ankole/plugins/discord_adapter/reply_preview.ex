defmodule Ankole.Plugins.DiscordAdapter.ReplyPreview do
  @moduledoc "Crash-recoverable Discord mutable reply lifecycle."

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

  alias Ankole.Plugins.DiscordAdapter.{Client, Config, ErrorPolicy, Outbox, Presentation}
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
    |> Enum.reduce_while({:ok, existing, []}, fn {chunk, index}, {:ok, records, responses} ->
      current = Map.get(records, index)

      case upsert_message(client, event, current, chunk, channel, index) do
        {:ok, message, response} ->
          records = Map.put(records, index, message)
          staged_messages = sorted_message_records(records)
          staged = build_checkpoint(checkpoint, staged_messages, presentation, request)

          case Actors.put_reply_preview_checkpoint(event.id, staged) do
            {:ok, _event} ->
              {:cont, {:ok, records, [response | responses]}}

            {:error, _reason} ->
              {:halt, {:error, :discord_partial_delivery}}
          end

        {:error, :discord_send_uncertain} ->
          {:halt, {:error, :discord_send_uncertain}}

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

        with :ok <- delete_surplus_messages(client, existing, length(messages), channel) do
          {:ok, messages, Enum.reverse(responses)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # A checkpointed message that Discord no longer has is not an error: the
  # human deleted it, and the reply continues by posting the chunk again.
  defp upsert_message(
         client,
         event,
         %{"message_id" => message_id} = current,
         chunk,
         channel,
         index
       )
       when is_binary(message_id) do
    body = message_body(%{"content" => chunk["content"], "components" => chunk["components"]})

    case Client.patch(client, message_path(channel, message_id), body) do
      {:ok, response} ->
        {:ok, Map.put(current, "index", index), compact_response(response)}

      {:error, %Client.Error{status: 404}} ->
        post_message(client, event, chunk, channel, index)

      {:error, %Client.Error{} = error} ->
        {:error, error}
    end
  end

  defp upsert_message(client, event, _missing, chunk, channel, index),
    do: post_message(client, event, chunk, channel, index)

  defp post_message(client, event, chunk, channel, index) do
    body =
      %{"content" => chunk["content"], "components" => chunk["components"]}
      |> maybe_reply(event)
      |> message_body()

    case Client.post(client, "/channels/#{channel.channel_id}/messages", body) do
      {:ok, %{"id" => message_id} = response} when is_binary(message_id) ->
        case maybe_record_first_message(event, message_id) do
          :ok ->
            {:ok, %{"index" => index, "message_id" => message_id}, compact_response(response)}

          {:error, _reason} ->
            {:error, :discord_partial_delivery}
        end

      {:ok, _invalid} ->
        {:error, :discord_send_uncertain}

      {:error, %Client.Error{} = error} ->
        uncertain_create_or_error(error)
    end
  end

  defp maybe_reply(body, %ActorEvent{} = event) do
    case ActorEvent.reply_anchor_source_entry_id(event) |> Outbox.message_id() do
      {:ok, source_entry_id} ->
        Map.put(body, "message_reference", %{
          "message_id" => source_entry_id,
          "fail_if_not_exists" => false
        })

      {:error, _reason} ->
        body
    end
  end

  defp maybe_reply(body, _event), do: body

  defp maybe_record_first_message(%ActorEvent{reply_preview_source_entry_id: nil} = event, id),
    do: Actors.record_reply_preview_source_entry(event.id, id, event.signal_channel_id)

  defp maybe_record_first_message(_event, _id), do: :ok

  defp delete_surplus_messages(client, existing, retained_count, channel) do
    existing
    |> Enum.filter(fn {index, _message} -> index >= retained_count end)
    |> Enum.reduce_while(:ok, fn {_index, %{"message_id" => message_id}}, :ok ->
      case Client.delete(client, message_path(channel, message_id)) do
        {:ok, _response} -> {:cont, :ok}
        {:error, %Client.Error{status: 404}} -> {:cont, :ok}
        {:error, %Client.Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp build_checkpoint(checkpoint, messages, presentation, request) do
    previous = checkpoint["presentation"]
    terminal? = request.mode == :terminal or ReplyPresentation.terminal_state?(presentation)

    checkpoint
    |> Map.merge(%{
      "schema_version" => @checkpoint_version,
      "adapter" => "discord",
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

  defp message_path(channel, message_id),
    do: "/channels/#{channel.channel_id}/messages/#{message_id}"

  defp uncertain_create_or_error(%Client.Error{kind: :transport}),
    do: {:error, :discord_send_uncertain}

  defp uncertain_create_or_error(%Client.Error{status: status})
       when is_integer(status) and status >= 500,
       do: {:error, :discord_send_uncertain}

  defp uncertain_create_or_error(%Client.Error{} = error), do: {:error, error}

  defp message_body(body) do
    Map.put(body, "allowed_mentions", %{"parse" => [], "replied_user" => false})
  end

  defp compact_response(%{} = response),
    do: Map.take(response, ["id", "timestamp", "edited_timestamp"])

  defp compact_response(_response), do: %{}

  defp maybe_put_payload(result, %{} = outbox), do: Map.put(result, :payload, outbox.payload)
  defp maybe_put_payload(result, _outbox), do: result
end
