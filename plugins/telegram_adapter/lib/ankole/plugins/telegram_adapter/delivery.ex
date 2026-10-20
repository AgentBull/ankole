defmodule Ankole.Plugins.TelegramAdapter.Delivery do
  import Ankole.Conversations.Delivery.Adapter, only: [combine_results: 2]
  @moduledoc false

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Attrs
  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.MapHelpers

  alias Ankole.Plugins.TelegramAdapter.Client
  alias Ankole.Plugins.TelegramAdapter.Config
  alias Ankole.Plugins.TelegramAdapter.Emoji
  alias Ankole.Plugins.TelegramAdapter.ErrorPolicy
  alias Ankole.Plugins.TelegramAdapter.Presentation

  alias Ankole.Conversations.Delivery.Intent

  @caption_chars 1_000

  @impl true
  def deliver(%Intent{} = intent) do
    result =
      with {:ok, config} <- Bindings.delivery_config(intent, Config),
           config = Config.runtime_config(config),
           client <- Config.client(config),
           {:ok, requests} <- requests_for_intent(intent) do
        perform_requests(requests, client, intent)
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  @doc false
  @spec requests_for_intent(Intent.t()) :: {:ok, [map()]} | {:error, term()}
  def requests_for_intent(%Intent{operation: operation} = intent)
      when operation in [:post, :reply] do
    case MapHelpers.fetch_list(intent.payload, "attachments") do
      [] -> text_requests(intent)
      attachments -> attachment_requests(intent, attachments)
    end
  end

  def requests_for_intent(%Intent{operation: :edit} = intent) do
    with {:ok, target} <- message_id(intent.target_provider_message_id),
         {:ok, channel} <- parse_channel(intent.conversation_id) do
      requests =
        intent.fallback_visible_text
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

  def requests_for_intent(%Intent{operation: :delete} = intent) do
    with {:ok, target} <- message_id(intent.target_provider_message_id),
         {:ok, channel} <- parse_channel(intent.conversation_id) do
      {:ok, [request("deleteMessage", %{"chat_id" => channel.chat_id, "message_id" => target})]}
    end
  end

  def requests_for_intent(%Intent{operation: operation} = intent)
      when operation in [:reaction_add, :reaction_remove] do
    with {:ok, target} <- message_id(intent.target_provider_message_id),
         {:ok, channel} <- parse_channel(intent.conversation_id) do
      reaction =
        intent.payload
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

  def requests_for_intent(%Intent{operation: :divider} = intent) do
    text =
      case String.trim(to_string(intent.fallback_visible_text || "")) do
        "" -> "────────"
        value -> "────────\n#{value}"
      end

    text_requests(%{intent | fallback_visible_text: text})
  end

  def requests_for_intent(%Intent{operation: :card} = intent) do
    with {:ok, channel} <- parse_channel(intent.conversation_id),
         {:ok, messages} <-
           Presentation.card(
             intent.payload,
             intent.fallback_visible_text || "",
             intent.source_signal_id
           ) do
      {:ok,
       Enum.map(messages, fn message ->
         body = send_body(channel, message["text"])
         body = maybe_put(body, "reply_markup", message["reply_markup"])
         body = maybe_reply(body, intent.reply_to_provider_message_id)
         request("sendMessage", body)
       end)}
    end
  end

  def requests_for_intent(_intent), do: {:error, :unsupported_intent_operation}

  defp text_requests(intent) do
    with {:ok, channel} <- parse_channel(intent.conversation_id) do
      requests =
        intent.fallback_visible_text
        |> Presentation.chunks()
        |> Enum.map(fn text ->
          body = channel |> send_body(text) |> maybe_reply(reply_id(intent))
          request("sendMessage", body)
        end)

      {:ok, requests}
    end
  end

  defp attachment_requests(intent, attachments) do
    with {:ok, channel} <- parse_channel(intent.conversation_id) do
      {caption, remaining_text} = split_caption(intent.fallback_visible_text || "")

      file_requests =
        attachments
        |> Enum.with_index()
        |> Enum.map(fn {attachment, index} ->
          attachment_request(
            intent,
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
                  body = channel |> send_body(text) |> maybe_reply(reply_id(intent))
                  request("sendMessage", body)
                end)
            end

          {:ok, requests ++ trailing}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp attachment_request(intent, channel, attachment, caption) do
    field = if image_attachment?(attachment), do: "photo", else: "document"
    method = if field == "photo", do: "sendPhoto", else: "sendDocument"
    base = send_body(channel, nil) |> Map.delete("text")
    base = maybe_put(base, "caption", Attrs.optional_text(caption))
    base = maybe_reply(base, reply_id(intent))

    case MapHelpers.optional_text(attachment, "provider_file_id") do
      file_id when is_binary(file_id) ->
        {:ok, request(method, Map.put(base, field, file_id))}

      nil ->
        with {:ok, content, name} <- attachment_content(attachment) do
          fields =
            base
            |> Enum.map(fn {key, value} ->
              {key, if(is_map(value) or is_list(value), do: Torque.encode!(value), else: value)}
            end)
            |> Kernel.++([
              {field,
               {content,
                filename: name,
                content_type: attachment["mime_type"] || "application/octet-stream"}}
            ])

          {:ok, %{method: method, multipart: fields}}
        end
    end
  end

  defp perform_requests(requests, client, intent) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, results} ->
      case perform(request, client) do
        {:ok, result} ->
          body = request[:body] || Map.new(request[:multipart] || [])
          text = body["text"] || body["caption"]
          result = Map.put(result, :text, text)
          {:cont, {:ok, [result | results]}}

        :unknown ->
          {:halt, :unknown}

        {:error, _reason} when results != [] ->
          {:halt, :unknown}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, combine_results(Enum.reverse(results), intent)}
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
       created_provider_message_id: integer_text(result["message_id"]),
       provider_time: provider_time(result["date"]),
       raw_payload:
         MapHelpers.compact_map(%{"message_id" => result["message_id"], "date" => result["date"]})
     }}
  end

  defp normalize_call_result({:ok, true}), do: {:ok, %{raw_payload: %{"ok" => true}}}

  defp normalize_call_result({:error, %Client.Error{} = error}) do
    if uncertain?(error), do: :unknown, else: {:error, error}
  end

  defp normalize_call_result(result), do: result

  defp provider_time(seconds) when is_integer(seconds), do: DateTime.from_unix!(seconds)
  defp provider_time(_), do: nil

  defp request(method, body), do: %{method: method, body: body}

  defp send_body(channel, text) do
    %{"chat_id" => channel.chat_id, "text" => text}
    |> maybe_put("message_thread_id", channel.topic_id)
  end

  defp maybe_reply(body, nil), do: body

  defp maybe_reply(body, provider_message_id) do
    case message_id(provider_message_id) do
      {:ok, id} -> Map.put(body, "reply_parameters", %{"message_id" => id})
      {:error, _reason} -> body
    end
  end

  defp reply_id(%Intent{operation: :reply, reply_to_provider_message_id: id}), do: id
  defp reply_id(_intent), do: nil

  @doc false
  def parse_channel(conversation_id) do
    with {:ok, conversation} <- Ankole.Conversations.External.fetch_conversation(conversation_id) do
      parse_provider_channel(conversation.provider_conversation_id)
    end
  end

  defp parse_provider_channel("telegram:" <> rest) do
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

  defp parse_provider_channel(_channel_id), do: {:error, :invalid_telegram_channel_id}

  defp message_id(value), do: integer_value(value)

  @doc false
  def integer_value(value) do
    case Attrs.integer_value(value) do
      nil -> {:error, :invalid_telegram_message_id}
      integer -> {:ok, integer}
    end
  end

  defp split_caption(text) do
    graphemes = String.graphemes(to_string(text))
    {caption, rest} = Enum.split(graphemes, @caption_chars)
    {Enum.join(caption), Enum.join(rest)}
  end

  defp attachment_content(attachment) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment) do
      {:ok, content, attachment["name"] || Path.basename(attachment["path"] || "attachment")}
    end
  end

  defp image_attachment?(attachment) do
    String.starts_with?(attachment["mime_type"] || "", "image/")
  end

  defp uncertain?(%Client.Error{kind: kind, error_code: code}),
    do: kind == :transport or (is_integer(code) and code >= 500)

  @doc false
  def idempotent_absence?(method, %Client.Error{error_code: 400, description: description})
      when method in ["deleteMessage", "editMessageText"] and is_binary(description) do
    downcased = String.downcase(description)

    String.contains?(downcased, "message to delete not found") or
      String.contains?(downcased, "message is not modified")
  end

  def idempotent_absence?(_method, _error), do: false

  defp integer_text(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_text(value) when is_binary(value), do: value
  defp integer_text(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
