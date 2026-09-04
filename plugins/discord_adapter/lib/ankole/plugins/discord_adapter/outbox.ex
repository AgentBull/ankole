defmodule Ankole.Plugins.DiscordAdapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.MapHelpers

  alias Ankole.Plugins.DiscordAdapter.{
    Client,
    Config,
    Emoji,
    ErrorPolicy,
    Presentation
  }

  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.WorkerFiles

  @impl true
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
    with {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      attachments = MapHelpers.fetch_list(outbox.payload, "attachments")

      outbox.fallback_visible_text
      |> content_chunks(attachments)
      |> Enum.with_index()
      |> Enum.map(fn {content, index} ->
        %{}
        |> maybe_put("content", content)
        |> maybe_reply(if(index == 0, do: reply_id(outbox)))
        |> message_body()
        |> post_request(channel, if(index == 0, do: attachments, else: []), outbox.agent_uid)
      end)
      |> MapHelpers.collect_results()
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

  def requests_for_outbox(%OutboxEntry{operation: :delete} = outbox) do
    with {:ok, target} <- message_id(outbox.target_source_entry_id),
         {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      {:ok, [request(:delete, "/channels/#{channel.channel_id}/messages/#{target}", nil)]}
    end
  end

  def requests_for_outbox(%OutboxEntry{operation: operation} = outbox)
      when operation in [:reaction_add, :reaction_remove] do
    with {:ok, target} <- message_id(outbox.target_source_entry_id),
         {:ok, channel} <- parse_channel(outbox.signal_channel_id) do
      emoji =
        (MapHelpers.fetch_value(outbox.payload, "raw_reaction_key") ||
           MapHelpers.fetch_value(outbox.payload, "reaction_key"))
        |> Emoji.path_segment()

      path = "/channels/#{channel.channel_id}/messages/#{target}/reactions/#{emoji}/@me"
      method = if operation == :reaction_add, do: :put, else: :delete

      {:ok, [request(method, path, if(method == :put, do: %{}))]}
    end
  end

  def requests_for_outbox(%OutboxEntry{operation: :divider} = outbox) do
    text =
      case String.trim(to_string(outbox.fallback_visible_text || "")) do
        "" -> "────────"
        value -> "────────\n#{value}"
      end

    requests_for_outbox(%{outbox | operation: :post, fallback_visible_text: text, payload: %{}})
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
         body =
           message
           |> compact_components()
           |> maybe_reply(outbox.reply_to_source_entry_id)
           |> message_body()

         request(:post, "/channels/#{channel.channel_id}/messages", body)
       end)}
    end
  end

  def requests_for_outbox(_outbox), do: {:error, :unsupported_outbox_operation}

  # An attachment carries the message on its own, so a blank text must not
  # become the placeholder that a text-only reply needs.
  defp content_chunks(text, []), do: Presentation.chunks(text)

  defp content_chunks(text, _attachments) do
    case MapHelpers.presence(to_string(text || "")) do
      nil -> [nil]
      value -> Presentation.chunks(value)
    end
  end

  defp post_request(body, channel, [], _agent_uid) do
    {:ok, request(:post, "/channels/#{channel.channel_id}/messages", body)}
  end

  # Discord carries an upload as one multipart request whose `payload_json`
  # part holds the ordinary message body and whose `files[n]` parts hold the
  # bytes, so text and attachments arrive as one message rather than two.
  defp post_request(body, channel, attachments, agent_uid) do
    attachments
    |> Enum.map(&attachment_file(&1, agent_uid))
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

  defp attachment_file(attachment, agent_uid) do
    relative = MapHelpers.optional_text(attachment, "user_files_relative_path")
    lane_path = if relative, do: Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

    with path when is_binary(path) <- lane_path,
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", path) do
      {:ok,
       %{
         content: content,
         filename: attachment["name"] || Path.basename(relative),
         content_type: attachment["mime_type"]
       }}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
    end
  end

  defp perform_requests(requests, client, outbox) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, results} ->
      case perform(request, client) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        :complete -> {:halt, {:ok, results}}
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
       created_source_entry_id: MapHelpers.optional_text(result, "id"),
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

  defp request(method, path, body), do: %{method: method, path: path, body: body}

  defp message_body(body) do
    Map.put(body, "allowed_mentions", %{"parse" => [], "replied_user" => false})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_reply(body, nil), do: body

  # `fail_if_not_exists` keeps a reply to an already deleted message from
  # failing the whole send; Discord posts it as an ordinary message instead.
  defp maybe_reply(body, source_entry_id) do
    case message_id(source_entry_id) do
      {:ok, id} ->
        Map.put(body, "message_reference", %{
          "message_id" => id,
          "fail_if_not_exists" => false
        })

      {:error, _reason} ->
        body
    end
  end

  defp reply_id(%OutboxEntry{operation: :reply, reply_to_source_entry_id: id}), do: id
  defp reply_id(_outbox), do: nil

  @doc false
  def parse_channel("discord:" <> rest) do
    case String.split(rest, ":") do
      [bot_id, "channel", channel_id] when bot_id != "" and channel_id != "" ->
        {:ok, %{bot_id: bot_id, channel_id: channel_id}}

      _invalid ->
        {:error, :invalid_discord_channel_id}
    end
  end

  def parse_channel(_channel_id), do: {:error, :invalid_discord_channel_id}

  @doc false
  @spec message_id(term()) :: {:ok, String.t()} | {:error, term()}
  def message_id(value) when is_binary(value) and value != "", do: {:ok, value}
  def message_id(_value), do: {:error, :invalid_discord_message_id}

  defp compact_components(%{"components" => []} = message), do: Map.delete(message, "components")
  defp compact_components(message), do: message

  defp uncertain?(%Client.Error{kind: kind, status: status}),
    do: kind == :transport or (is_integer(status) and status >= 500)

  # A delete of a message another operator already removed, and an edit of the
  # same, are the outcome the outbox asked for.
  defp idempotent_absence?(method, %Client.Error{status: 404}) when method in [:delete, :patch],
    do: true

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
end
