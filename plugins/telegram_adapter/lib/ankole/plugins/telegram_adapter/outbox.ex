defmodule Ankole.Plugins.TelegramAdapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.MapHelpers

  alias Ankole.Plugins.TelegramAdapter.{
    Client,
    Config,
    Emoji,
    ErrorPolicy,
    Presentation,
    ReplyPreview
  }

  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{ActorEvent, OutboxEntry}
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias Ankole.WorkerFiles

  @caption_chars 1_000

  @impl true
  def send(
        %OutboxEntry{
          payload: %{"reply_presentation" => presentation},
          source_actor_event_id: actor_event_id
        } = outbox
      )
      when is_map(presentation) and is_binary(actor_event_id) do
    result =
      case Repo.get(ActorEvent, actor_event_id) do
        %ActorEvent{} = event ->
          checkpoint = event.reply_preview_checkpoint || %{}

          ReplyPreviewAdapter.finalize_module(ReplyPreview, %Request{
            actor_event: event,
            presentation: presentation,
            checkpoint: checkpoint,
            subject_uid: checkpoint["subject_uid"],
            conversation_id: checkpoint["conversation_id"],
            outbox: outbox,
            mode: :terminal
          })

        nil ->
          {:error, :actor_event_not_found}
      end

    case result do
      {:error, reason} when reason in [:telegram_partial_delivery, :telegram_send_uncertain] ->
        :unknown

      {:error,
       {:reply_delivery, :operator_action_required, %{"code" => "telegram_delivery_unknown"}}} ->
        :unknown

      other ->
        ErrorPolicy.normalize_delivery_result(other)
    end
  end

  def send(%OutboxEntry{} = outbox) do
    result =
      with {:ok, config} <- config_for_outbox(outbox),
           client <- Config.client(config),
           {:ok, requests} <- requests_for_outbox(outbox) do
        perform_requests(requests, client, outbox)
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  @doc false
  @spec requests_for_outbox(OutboxEntry.t()) :: {:ok, [map()]} | {:error, term()}
  def requests_for_outbox(%OutboxEntry{operation: operation} = outbox)
      when operation in [:post, :reply] do
    case MapHelpers.fetch_list(outbox.payload, "attachments") do
      [] -> text_requests(outbox)
      attachments -> attachment_requests(outbox, attachments)
    end
  end

  def requests_for_outbox(%OutboxEntry{operation: :edit} = outbox) do
    with {:ok, target} <- message_id(outbox.target_source_entry_id),
         {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      requests =
        outbox.fallback_visible_text
        |> Presentation.chunks()
        |> Enum.with_index()
        |> Enum.map(fn
          {text, 0} ->
            request("editMessageText", %{
              "chat_id" => channel.chat_id,
              "message_id" => target,
              "text" => text
            })

          {text, _index} ->
            request("sendMessage", send_body(channel, text))
        end)

      {:ok, requests}
    end
  end

  def requests_for_outbox(%OutboxEntry{operation: :delete} = outbox) do
    with {:ok, target} <- message_id(outbox.target_source_entry_id),
         {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      {:ok, [request("deleteMessage", %{"chat_id" => channel.chat_id, "message_id" => target})]}
    end
  end

  def requests_for_outbox(%OutboxEntry{operation: operation} = outbox)
      when operation in [:reaction_add, :reaction_remove] do
    with {:ok, target} <- message_id(outbox.target_source_entry_id),
         {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      reaction =
        outbox.payload
        |> MapHelpers.fetch_value("reaction_key")
        |> Emoji.provider_key()

      reactions =
        if operation == :reaction_add,
          do: [%{"type" => "emoji", "emoji" => reaction}],
          else: []

      {:ok,
       [
         request("setMessageReaction", %{
           "chat_id" => channel.chat_id,
           "message_id" => target,
           "reaction" => reactions
         })
       ]}
    end
  end

  def requests_for_outbox(%OutboxEntry{operation: :divider} = outbox) do
    text =
      case String.trim(to_string(outbox.fallback_visible_text || "")) do
        "" -> "────────"
        value -> "────────\n#{value}"
      end

    text_requests(%{outbox | fallback_visible_text: text})
  end

  def requests_for_outbox(%OutboxEntry{operation: :card} = outbox) do
    with {:ok, channel} <- parse_channel(outbox.signal_channel_id),
         {:ok, messages} <-
           Presentation.card(
             outbox.payload,
             outbox.fallback_visible_text || "",
             outbox.source_actor_event_id
           ) do
      {:ok,
       Enum.map(messages, fn message ->
         body = send_body(channel, message["text"])
         body = maybe_put(body, "reply_markup", message["reply_markup"])
         body = maybe_reply(body, outbox.reply_to_source_entry_id)
         request("sendMessage", body)
       end)}
    end
  end

  def requests_for_outbox(_outbox), do: {:error, :unsupported_outbox_operation}

  defp text_requests(outbox) do
    with {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      requests =
        outbox.fallback_visible_text
        |> Presentation.chunks()
        |> Enum.map(fn text ->
          body = channel |> send_body(text) |> maybe_reply(reply_id(outbox))
          request("sendMessage", body)
        end)

      {:ok, requests}
    end
  end

  defp attachment_requests(outbox, attachments) do
    with {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      {caption, remaining_text} = split_caption(outbox.fallback_visible_text || "")

      file_requests =
        attachments
        |> Enum.with_index()
        |> Enum.map(fn {attachment, index} ->
          attachment_request(
            outbox,
            channel,
            attachment,
            if(index == 0, do: caption, else: nil)
          )
        end)

      case MapHelpers.collect_results(file_requests) do
        {:ok, requests} ->
          trailing =
            case String.trim(remaining_text) do
              "" ->
                []

              _text ->
                remaining_text
                |> Presentation.chunks()
                |> Enum.map(fn text ->
                  body = channel |> send_body(text) |> maybe_reply(reply_id(outbox))
                  request("sendMessage", body)
                end)
            end

          {:ok, requests ++ trailing}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp attachment_request(outbox, channel, attachment, caption) do
    field = if image_attachment?(attachment), do: "photo", else: "document"
    method = if field == "photo", do: "sendPhoto", else: "sendDocument"
    base = send_body(channel, nil) |> Map.delete("text")
    base = maybe_put(base, "caption", blank_to_nil(caption))
    base = maybe_reply(base, reply_id(outbox))

    case MapHelpers.optional_text(attachment, "provider_file_id") do
      file_id when is_binary(file_id) ->
        {:ok, request(method, Map.put(base, field, file_id))}

      nil ->
        with {:ok, content, name} <- attachment_content(attachment, outbox.agent_uid) do
          fields =
            base
            |> Enum.map(fn {key, value} ->
              {key, if(is_map(value) or is_list(value), do: Torque.encode!(value), else: value)}
            end)
            |> Kernel.++([
              {field,
               {content,
                filename: name, content_type: attachment["mimetype"] || "application/octet-stream"}}
            ])

          {:ok, %{method: method, multipart: fields}}
        end
    end
  end

  defp perform_requests(requests, client, outbox) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, results} ->
      case perform(request, client) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        :unknown -> {:halt, :unknown}
        {:error, _reason} when results != [] -> {:halt, :unknown}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, combine_results(Enum.reverse(results), outbox)}
      other -> other
    end
  end

  defp perform(%{method: method, multipart: fields}, client) do
    Client.call_multipart(client, method, fields) |> normalize_call_result()
  end

  defp perform(%{method: method, body: body}, client) do
    case Client.call(client, method, body) do
      {:error, %Client.Error{} = error} = result ->
        cond do
          idempotent_absence?(method, error) -> {:ok, %{}}
          uncertain?(error) -> :unknown
          true -> result
        end

      result ->
        normalize_call_result(result)
    end
  end

  defp normalize_call_result({:ok, result}) when is_map(result) do
    {:ok,
     %{
       created_source_entry_id: integer_text(result["message_id"]),
       raw_payload:
         MapHelpers.compact_map(%{"message_id" => result["message_id"], "date" => result["date"]})
     }}
  end

  defp normalize_call_result({:ok, true}), do: {:ok, %{raw_payload: %{"ok" => true}}}

  defp normalize_call_result({:error, %Client.Error{} = error}) do
    if uncertain?(error), do: :unknown, else: {:error, error}
  end

  defp normalize_call_result(result), do: result

  defp combine_results(results, outbox) do
    first = List.first(results) || %{}

    %{
      created_source_entry_id: first[:created_source_entry_id],
      provider_thread_id: outbox.signal_channel_id,
      raw_payload: %{"messages" => Enum.map(results, & &1[:raw_payload])},
      payload: outbox.payload
    }
    |> MapHelpers.compact_map()
  end

  defp request(method, body), do: %{method: method, body: body}

  defp send_body(channel, text) do
    %{"chat_id" => channel.chat_id, "text" => text}
    |> maybe_put("message_thread_id", channel.topic_id)
  end

  defp maybe_reply(body, nil), do: body

  defp maybe_reply(body, source_entry_id) do
    case message_id(source_entry_id) do
      {:ok, id} -> Map.put(body, "reply_parameters", %{"message_id" => id})
      {:error, _reason} -> body
    end
  end

  defp reply_id(%OutboxEntry{operation: :reply, reply_to_source_entry_id: id}), do: id
  defp reply_id(_outbox), do: nil

  @doc false
  def parse_channel("telegram:" <> rest) do
    case String.split(rest, ":") do
      [bot_id, "chat", chat_id] ->
        {:ok, %{bot_id: bot_id, chat_id: chat_id, topic_id: nil}}

      [bot_id, "chat", chat_id, "topic", topic_id] ->
        with {:ok, topic_id} <- integer_value(topic_id) do
          {:ok, %{bot_id: bot_id, chat_id: chat_id, topic_id: topic_id}}
        end

      _invalid ->
        {:error, :invalid_telegram_channel_id}
    end
  end

  def parse_channel(_channel_id), do: {:error, :invalid_telegram_channel_id}

  defp message_id(value), do: integer_value(value)

  @doc false
  def integer_value(value) when is_integer(value), do: {:ok, value}

  def integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> {:error, :invalid_telegram_message_id}
    end
  end

  def integer_value(_value), do: {:error, :invalid_telegram_message_id}

  defp split_caption(text) do
    graphemes = String.graphemes(to_string(text))
    {caption, rest} = Enum.split(graphemes, @caption_chars)
    {Enum.join(caption), Enum.join(rest)}
  end

  defp attachment_content(attachment, agent_uid) do
    relative = MapHelpers.optional_text(attachment, "user_files_relative_path")
    lane_path = if relative, do: Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

    with path when is_binary(path) <- lane_path,
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", path) do
      {:ok, content, attachment["name"] || Path.basename(relative)}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
    end
  end

  defp image_attachment?(attachment) do
    String.starts_with?(attachment["mimetype"] || "", "image/")
  end

  defp uncertain?(%Client.Error{kind: kind, error_code: code}),
    do: kind == :transport or (is_integer(code) and code >= 500)

  defp idempotent_absence?(method, %Client.Error{error_code: 400, description: description})
       when method in ["deleteMessage", "editMessageText"] and is_binary(description) do
    downcased = String.downcase(description)

    String.contains?(downcased, "message to delete not found") or
      String.contains?(downcased, "message is not modified")
  end

  defp idempotent_absence?(_method, _error), do: false

  defp config_for_outbox(outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp integer_text(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_text(value) when is_binary(value), do: value
  defp integer_text(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
