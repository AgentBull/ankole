defmodule Ankole.Plugins.SlackAdapter.Delivery do
  @moduledoc false

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.SlackAdapter.BlockKit
  alias Ankole.Plugins.SlackAdapter.Config
  alias Ankole.Plugins.SlackAdapter.Emoji
  alias Ankole.Plugins.SlackAdapter.ErrorPolicy
  alias Ankole.Plugins.SlackAdapter.Mrkdwn
  alias Ankole.Conversations.Delivery.Intent
  alias SlackOpenAPI.Error

  @max_text_chars 12_000

  @impl true
  defdelegate open_conversation(binding, principal_uid),
    to: Ankole.Conversations.External,
    as: :existing_direct_conversation

  @impl true
  def deliver(%Intent{} = intent) do
    result =
      with {:ok, config} <- Bindings.delivery_config(intent, Config),
           client <- Config.client(config) do
        case MapHelpers.fetch_list(intent.payload, "attachments") do
          [] -> send_requests(intent, client)
          [attachment] -> send_attachment(intent, attachment, client)
        end
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  @impl true
  def reconcile(%Intent{created_provider_message_id: nil}), do: :unknown

  def reconcile(%Intent{} = intent) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         client <- Config.client(config),
         channel <- channel_id(intent.conversation_id),
         {:ok, body} <-
           SlackOpenAPI.get(client, "conversations.history",
             query: [
               channel: channel,
               latest: intent.created_provider_message_id,
               oldest: intent.created_provider_message_id,
               inclusive: true,
               limit: 1
             ]
           ) do
      if Enum.any?(
           Map.get(body, "messages", []),
           &(&1["ts"] == intent.created_provider_message_id)
         ) do
        {:ok,
         %{
           created_provider_message_id: intent.created_provider_message_id,
           raw_payload: body,
           recovery_state: %{"exists" => true}
         }}
      else
        :unknown
      end
    end
  end

  @doc false
  @spec requests_for_intent(Intent.t()) :: {:ok, [map()]} | {:error, term()}
  def requests_for_intent(%Intent{operation: operation} = intent)
      when operation in [:post, :reply] do
    requests =
      intent.fallback_visible_text
      |> to_string()
      |> split_text()
      |> Enum.map(fn text ->
        body = %{
          "channel" => channel_id(intent.conversation_id),
          "text" => Mrkdwn.from_markdown(text)
        }

        body =
          if operation == :reply,
            do: Map.put(body, "thread_ts", intent.reply_to_provider_message_id),
            else: body

        %{method: "chat.postMessage", body: body, reply?: operation == :reply}
      end)

    {:ok, requests}
  end

  def requests_for_intent(%Intent{operation: :edit} = intent) do
    requests =
      intent.fallback_visible_text
      |> to_string()
      |> split_text()
      |> Enum.with_index(1)
      |> Enum.map(fn
        {text, 1} ->
          %{
            method: "chat.update",
            body: %{
              "channel" => channel_id(intent.conversation_id),
              "ts" => intent.target_provider_message_id,
              "text" => Mrkdwn.from_markdown(text)
            }
          }

        {text, _index} ->
          %{
            method: "chat.postMessage",
            body: %{
              "channel" => channel_id(intent.conversation_id),
              "text" => Mrkdwn.from_markdown(text)
            }
          }
      end)

    {:ok, requests}
  end

  def requests_for_intent(%Intent{operation: :delete} = intent) do
    {:ok,
     [
       %{
         method: "chat.delete",
         body: %{
           "channel" => channel_id(intent.conversation_id),
           "ts" => intent.target_provider_message_id
         },
         idempotent_error: "message_not_found"
       }
     ]}
  end

  def requests_for_intent(%Intent{operation: operation} = intent)
      when operation in [:reaction_add, :reaction_remove] do
    reaction_key =
      intent.payload
      |> MapHelpers.fetch_value("reaction_key")
      |> to_string()
      |> Emoji.provider_key()

    {:ok,
     [
       %{
         method: if(operation == :reaction_add, do: "reactions.add", else: "reactions.remove"),
         body: %{
           "channel" => channel_id(intent.conversation_id),
           "timestamp" => intent.target_provider_message_id,
           "name" => reaction_key
         },
         idempotent_error:
           if(operation == :reaction_add, do: "already_reacted", else: "no_reaction")
       }
     ]}
  end

  def requests_for_intent(%Intent{operation: :divider} = intent) do
    text =
      intent.fallback_visible_text
      |> to_string()
      |> String.trim()
      |> truncate(150)
      |> Mrkdwn.from_markdown()

    {:ok,
     [
       %{
         method: "chat.postMessage",
         body: %{
           "channel" => channel_id(intent.conversation_id),
           "text" => text,
           "blocks" => [
             %{"type" => "divider"},
             %{"type" => "context", "elements" => [%{"type" => "mrkdwn", "text" => text}]}
           ]
         }
       }
     ]}
  end

  def requests_for_intent(%Intent{operation: :card} = intent) do
    with {:ok, blocks} <- BlockKit.render(intent.payload) do
      requests =
        blocks
        |> BlockKit.split_blocks()
        |> Enum.map(fn chunk ->
          fallback =
            intent.fallback_visible_text
            |> to_string()
            |> Mrkdwn.from_markdown()
            |> truncate(3_000)

          body = %{
            "channel" => channel_id(intent.conversation_id),
            "text" => fallback,
            "blocks" => chunk
          }

          body =
            if is_binary(intent.reply_to_provider_message_id),
              do: Map.put(body, "thread_ts", intent.reply_to_provider_message_id),
              else: body

          %{method: "chat.postMessage", body: body}
        end)

      {:ok, requests}
    end
  end

  def requests_for_intent(_intent), do: {:error, :unsupported_intent_operation}

  defp send_requests(intent, client) do
    with {:ok, requests} <- requests_for_intent(intent) do
      requests
      |> Enum.reduce_while([], fn request, results ->
        case perform(request, client) |> maybe_reply_fallback(request, intent, client) do
          {:ok, result} -> {:cont, [result | results]}
          {:error, _reason} when results != [] -> {:halt, :unknown}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        :unknown ->
          :unknown

        {:error, _reason} = error ->
          error

        results ->
          {:ok, combine_results(Enum.reverse(results)) |> Map.put(:payload, intent.payload)}
      end
    end
  end

  defp perform(request, client) do
    case SlackOpenAPI.post(client, request.method, body: request.body) do
      {:ok, body} ->
        normalize_success(body, request.body)

      {:error, %Error{reason: :rate_limited, retry_after: seconds}} ->
        {:error, {:rate_limited, seconds}}

      {:error, %Error{reason: reason} = error} ->
        if reason == request[:idempotent_error] do
          {:ok, %{raw_payload: %{"ok" => true, "already_absent_or_applied" => true}}}
        else
          {:error, error}
        end
    end
  end

  defp maybe_reply_fallback(
         {:error, %Error{reason: reason}},
         %{reply?: true, body: body},
         _intent,
         client
       )
       when reason in ["thread_not_found", "message_not_found"] do
    SlackOpenAPI.post(client, "chat.postMessage", body: Map.delete(body, "thread_ts"))
    |> case do
      {:ok, result} -> normalize_success(result, Map.delete(body, "thread_ts"))
      {:error, _reason} = error -> error
    end
  end

  defp maybe_reply_fallback(result, _request, _intent, _client), do: result

  defp normalize_success(%{"ts" => ts} = body, request_body) do
    {:ok,
     %{
       created_provider_message_id: ts,
       provider_thread_id: response_thread_id(body, request_body),
       text: request_body["text"],
       raw_payload: body
     }
     |> MapHelpers.compact_map()}
  end

  defp normalize_success(body, _request_body), do: {:ok, %{raw_payload: body}}

  defp response_thread_id(body, request_body) do
    channel =
      MapHelpers.optional_text(body, "channel") ||
        MapHelpers.optional_text(request_body, "channel")

    thread_ts =
      get_in(body, ["message", "thread_ts"]) ||
        MapHelpers.optional_text(request_body, "thread_ts")

    if is_binary(channel) and is_binary(thread_ts),
      do: "slack:#{URI.encode(channel)}:#{URI.encode(thread_ts)}"
  end

  defp combine_results([result]), do: Map.put(result, :messages, [result])

  defp combine_results(results) do
    first = List.first(results) || %{}

    %{
      created_provider_message_id: first[:created_provider_message_id],
      provider_thread_id: first[:provider_thread_id],
      messages: results,
      raw_payload: %{"split" => true, "chunks" => Enum.map(results, & &1.raw_payload)}
    }
    |> MapHelpers.compact_map()
  end

  defp send_attachment(intent, attachment, client) do
    case MapHelpers.optional_text(attachment, "provider_file_id") do
      file_id when is_binary(file_id) ->
        {:ok,
         %{
           raw_payload: %{"ok" => true, "file_id" => file_id, "already_uploaded" => true},
           payload: intent.payload
         }}

      nil ->
        upload_attachment(intent, attachment, client)
    end
  end

  defp upload_attachment(intent, attachment, client) do
    with {:ok, content, name} <- attachment_content(attachment),
         {:ok, body} <-
           SlackOpenAPI.upload_external(client,
             filename: name,
             content: content,
             channel_id: channel_id(intent.conversation_id),
             thread_ts: intent.reply_to_provider_message_id
           ) do
      payload =
        Map.update(intent.payload, "attachments", [], fn attachments ->
          Enum.map(attachments, &Map.put(&1, "provider_file_id", first_file_id(body)))
        end)

      {:ok, %{raw_payload: body, payload: payload}}
    end
  end

  defp attachment_content(attachment) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment) do
      {:ok, content,
       MapHelpers.optional_text(attachment, "name") || attachment_basename(attachment)}
    end
  end

  defp attachment_basename(%{"path" => path}) when is_binary(path), do: Path.basename(path)
  defp attachment_basename(_attachment), do: "attachment"

  defp first_file_id(%{"files" => [%{"id" => id} | _rest]}), do: id
  defp first_file_id(_body), do: nil

  defp split_text(text) do
    case text
         |> String.graphemes()
         |> Enum.chunk_every(@max_text_chars)
         |> Enum.map(&Enum.join/1) do
      [] -> [""]
      chunks -> chunks
    end
  end

  defp truncate(text, size), do: String.slice(text, 0, size)

  defp channel_id(conversation_id) do
    "slack:" <> encoded = Ankole.Conversations.External.provider_conversation_id!(conversation_id)
    URI.decode(encoded)
  end
end
