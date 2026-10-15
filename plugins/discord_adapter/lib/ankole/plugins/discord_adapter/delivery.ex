defmodule Ankole.Plugins.DiscordAdapter.Delivery do
  @moduledoc false

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.MapHelpers

  alias Ankole.Plugins.DiscordAdapter.Client
  alias Ankole.Plugins.DiscordAdapter.Config
  alias Ankole.Plugins.DiscordAdapter.Emoji
  alias Ankole.Plugins.DiscordAdapter.ErrorPolicy
  alias Ankole.Plugins.DiscordAdapter.Presentation

  alias Ankole.Conversations.Delivery.Intent

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
    with {:ok, channel} <- parse_channel(intent.conversation_id) do
      attachments = MapHelpers.fetch_list(intent.payload, "attachments")

      intent.fallback_visible_text
      |> content_chunks(attachments)
      |> Enum.with_index()
      |> Enum.map(fn {content, index} ->
        %{}
        |> maybe_put("content", content)
        |> maybe_reply(if(index == 0, do: reply_id(intent)))
        |> message_body()
        |> post_request(channel, if(index == 0, do: attachments, else: []))
      end)
      |> MapHelpers.collect_results()
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
            request(
              :patch,
              "/channels/#{channel.channel_id}/messages/#{target}",
              message_body(%{"content" => text})
            )

          {text, _index} ->
            request(
              :post,
              "/channels/#{channel.channel_id}/messages",
              message_body(%{"content" => text})
            )
        end)

      {:ok, requests}
    end
  end

  def requests_for_intent(%Intent{operation: :delete} = intent) do
    with {:ok, target} <- message_id(intent.target_provider_message_id),
         {:ok, channel} <- parse_channel(intent.conversation_id) do
      {:ok, [request(:delete, "/channels/#{channel.channel_id}/messages/#{target}", nil)]}
    end
  end

  def requests_for_intent(%Intent{operation: operation} = intent)
      when operation in [:reaction_add, :reaction_remove] do
    with {:ok, target} <- message_id(intent.target_provider_message_id),
         {:ok, channel} <- parse_channel(intent.conversation_id) do
      emoji =
        (MapHelpers.fetch_value(intent.payload, "raw_reaction_key") ||
           MapHelpers.fetch_value(intent.payload, "reaction_key"))
        |> Emoji.path_segment()

      path = "/channels/#{channel.channel_id}/messages/#{target}/reactions/#{emoji}/@me"
      method = if operation == :reaction_add, do: :put, else: :delete

      {:ok, [request(method, path, if(method == :put, do: %{}))]}
    end
  end

  def requests_for_intent(%Intent{operation: :divider} = intent) do
    text =
      case String.trim(to_string(intent.fallback_visible_text || "")) do
        "" -> "────────"
        value -> "────────\n#{value}"
      end

    requests_for_intent(%{intent | operation: :post, fallback_visible_text: text, payload: %{}})
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
         body =
           message
           |> compact_components()
           |> maybe_reply(intent.reply_to_provider_message_id)
           |> message_body()

         request(:post, "/channels/#{channel.channel_id}/messages", body)
       end)}
    end
  end

  def requests_for_intent(_intent), do: {:error, :unsupported_intent_operation}

  # An attachment carries the message on its own, so a blank text must not
  # become the placeholder that a text-only reply needs.
  defp content_chunks(text, []), do: Presentation.chunks(text)

  defp content_chunks(text, _attachments) do
    case MapHelpers.presence(to_string(text || "")) do
      nil -> [nil]
      value -> Presentation.chunks(value)
    end
  end

  defp post_request(body, channel, []) do
    {:ok, request(:post, "/channels/#{channel.channel_id}/messages", body)}
  end

  # Discord carries an upload as one multipart request whose `payload_json`
  # part holds the ordinary message body and whose `files[n]` parts hold the
  # bytes, so text and attachments arrive as one message rather than two.
  defp post_request(body, channel, attachments) do
    attachments
    |> Enum.map(&attachment_file/1)
    |> MapHelpers.collect_results()
    |> case do
      {:ok, files} ->
        {:ok,
         %{
           method: :post,
           path: "/channels/#{channel.channel_id}/messages",
           body: body,
           files: files
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp attachment_file(attachment) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment) do
      {:ok,
       %{
         content: content,
         filename: attachment["name"] || Path.basename(attachment["path"] || "attachment"),
         content_type: attachment["mime_type"]
       }}
    end
  end

  defp perform_requests(requests, client, intent) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, results} ->
      case perform(request, client) do
        {:ok, result} ->
          {:cont, {:ok, [Map.put(result, :text, (request[:body] || %{})["content"]) | results]}}

        :complete ->
          {:halt, {:ok, results}}

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

  defp perform(%{method: :post, path: path, body: body, files: files}, client) do
    client |> Client.post_multipart(path, body, files) |> normalize_message_create_result()
  end

  defp perform(%{method: :post, path: path, body: body}, client) do
    client |> Client.post(path, body || %{}) |> normalize_message_create_result()
  end

  defp perform(%{method: method, path: path, body: body}, client) do
    case call(client, method, path, body) do
      {:error, %Client.Error{} = error} = result ->
        cond do
          idempotent_absence?(method, error) -> :complete
          true -> result
        end

      result ->
        normalize_call_result(result)
    end
  end

  defp call(client, :patch, path, body), do: Client.patch(client, path, body || %{})
  defp call(client, :put, path, body), do: Client.put(client, path, body || %{})
  defp call(client, :delete, path, _body), do: Client.delete(client, path)

  defp normalize_call_result({:ok, result}) when is_map(result) do
    {:ok,
     %{
       created_provider_message_id: MapHelpers.optional_text(result, "id"),
       raw_payload:
         MapHelpers.compact_map(%{"id" => result["id"], "timestamp" => result["timestamp"]})
     }}
  end

  defp normalize_call_result({:ok, _result}), do: {:ok, %{raw_payload: %{}}}

  defp normalize_message_create_result({:ok, %{"id" => id} = result})
       when is_binary(id) and id != "",
       do: normalize_call_result({:ok, result})

  # Discord accepted the create, but without its message ID Ankole cannot
  # checkpoint or reconcile the side effect. Retrying could create a duplicate.
  defp normalize_message_create_result({:ok, _invalid}), do: :unknown

  defp normalize_message_create_result({:error, %Client.Error{} = error} = result) do
    if uncertain?(error), do: :unknown, else: result
  end

  defp combine_results(results, intent) do
    first = List.first(results) || %{}

    %{
      created_provider_message_id: first[:created_provider_message_id],
      provider_thread_id: intent.provider_thread_id,
      messages: results,
      raw_payload: %{"messages" => Enum.map(results, & &1[:raw_payload])},
      payload: intent.payload
    }
    |> MapHelpers.compact_map()
  end

  defp request(method, path, body), do: %{method: method, path: path, body: body}

  defp message_body(body) do
    Map.put(body, "allowed_mentions", %{"parse" => [], "replied_user" => false})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_reply(body, nil), do: body

  # `fail_if_not_exists` keeps a reply to an already deleted message from
  # failing the whole send; Discord posts it as an ordinary message instead.
  defp maybe_reply(body, provider_message_id) do
    case message_id(provider_message_id) do
      {:ok, id} ->
        Map.put(body, "message_reference", %{
          "message_id" => id,
          "fail_if_not_exists" => false
        })

      {:error, _reason} ->
        body
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

  defp parse_provider_channel("discord:" <> rest) do
    case String.split(rest, ":") do
      [bot_id, "channel", channel_id] when bot_id != "" and channel_id != "" ->
        {:ok, %{bot_id: bot_id, channel_id: channel_id}}

      _invalid ->
        {:error, :invalid_discord_channel_id}
    end
  end

  defp parse_provider_channel(_channel_id), do: {:error, :invalid_discord_channel_id}

  @doc false
  @spec message_id(term()) :: {:ok, String.t()} | {:error, term()}
  def message_id(value) when is_binary(value) and value != "", do: {:ok, value}
  def message_id(_value), do: {:error, :invalid_discord_message_id}

  defp compact_components(%{"components" => []} = message), do: Map.delete(message, "components")
  defp compact_components(message), do: message

  defp uncertain?(%Client.Error{kind: kind, status: status}),
    do: kind == :transport or (is_integer(status) and status >= 500)

  # A delete of a message another operator already removed, and an edit of the
  # same, are the outcome the intent asked for.
  defp idempotent_absence?(method, %Client.Error{status: 404}) when method in [:delete, :patch],
    do: true

  defp idempotent_absence?(_method, _error), do: false
end
