defmodule Ankole.Plugins.SlackAdapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.SlackAdapter.{BlockKit, Config, Emoji, MapHelpers, Mrkdwn}
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.WorkerFiles
  alias SlackOpenAPI.Error

  @max_text_chars 12_000

  @impl true
  def send(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config) do
      case MapHelpers.fetch_list(outbox.payload, "attachments") do
        [] -> send_requests(outbox, client)
        [attachment] -> send_attachment(outbox, attachment, client)
        _attachments -> {:error, :multiple_outbound_attachments_not_supported}
      end
    end
  end

  @impl true
  def reconcile(%OutboxEntry{created_source_entry_id: nil}), do: :unknown

  def reconcile(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config),
         channel <- channel_id(outbox.signal_channel_id),
         {:ok, body} <-
           SlackOpenAPI.get(client, "conversations.history",
             query: [
               channel: channel,
               latest: outbox.created_source_entry_id,
               oldest: outbox.created_source_entry_id,
               inclusive: true,
               limit: 1
             ]
           ) do
      if Enum.any?(Map.get(body, "messages", []), &(&1["ts"] == outbox.created_source_entry_id)) do
        {:ok,
         %{
           created_source_entry_id: outbox.created_source_entry_id,
           raw_payload: body,
           recovery_state: %{"exists" => true}
         }}
      else
        :unknown
      end
    end
  end

  @doc false
  @spec requests_for_outbox(OutboxEntry.t()) :: {:ok, [map()]} | {:error, term()}
  def requests_for_outbox(%OutboxEntry{operation: operation} = outbox)
      when operation in [:post, :reply] do
    requests =
      outbox.fallback_visible_text
      |> to_string()
      |> split_text()
      |> Enum.with_index(1)
      |> Enum.map(fn {text, index} ->
        body = %{
          "channel" => channel_id(outbox.signal_channel_id),
          "text" => Mrkdwn.from_markdown(text)
        }

        body =
          if operation == :reply and index == 1,
            do: Map.put(body, "thread_ts", outbox.reply_to_source_entry_id),
            else: body

        %{method: "chat.postMessage", body: body, reply?: operation == :reply and index == 1}
      end)

    {:ok, requests}
  end

  def requests_for_outbox(%OutboxEntry{operation: :edit} = outbox) do
    requests =
      outbox.fallback_visible_text
      |> to_string()
      |> split_text()
      |> Enum.with_index(1)
      |> Enum.map(fn
        {text, 1} ->
          %{
            method: "chat.update",
            body: %{
              "channel" => channel_id(outbox.signal_channel_id),
              "ts" => outbox.target_source_entry_id,
              "text" => Mrkdwn.from_markdown(text)
            }
          }

        {text, _index} ->
          %{
            method: "chat.postMessage",
            body: %{
              "channel" => channel_id(outbox.signal_channel_id),
              "text" => Mrkdwn.from_markdown(text)
            }
          }
      end)

    {:ok, requests}
  end

  def requests_for_outbox(%OutboxEntry{operation: :delete} = outbox) do
    {:ok,
     [
       %{
         method: "chat.delete",
         body: %{
           "channel" => channel_id(outbox.signal_channel_id),
           "ts" => outbox.target_source_entry_id
         },
         idempotent_error: "message_not_found"
       }
     ]}
  end

  def requests_for_outbox(%OutboxEntry{operation: operation} = outbox)
      when operation in [:reaction_add, :reaction_remove] do
    reaction_key =
      outbox.payload
      |> MapHelpers.fetch_value("reaction_key")
      |> to_string()
      |> Emoji.provider_key()

    {:ok,
     [
       %{
         method: if(operation == :reaction_add, do: "reactions.add", else: "reactions.remove"),
         body: %{
           "channel" => channel_id(outbox.signal_channel_id),
           "timestamp" => outbox.target_source_entry_id,
           "name" => reaction_key
         },
         idempotent_error:
           if(operation == :reaction_add, do: "already_reacted", else: "no_reaction")
       }
     ]}
  end

  def requests_for_outbox(%OutboxEntry{operation: :divider} = outbox) do
    text =
      outbox.fallback_visible_text
      |> to_string()
      |> String.trim()
      |> truncate(150)
      |> Mrkdwn.from_markdown()

    {:ok,
     [
       %{
         method: "chat.postMessage",
         body: %{
           "channel" => channel_id(outbox.signal_channel_id),
           "text" => text,
           "blocks" => [
             %{"type" => "divider"},
             %{"type" => "context", "elements" => [%{"type" => "mrkdwn", "text" => text}]}
           ]
         }
       }
     ]}
  end

  def requests_for_outbox(%OutboxEntry{operation: :card} = outbox) do
    with {:ok, blocks} <- BlockKit.render(outbox.payload) do
      requests =
        blocks
        |> BlockKit.split_blocks()
        |> Enum.with_index(1)
        |> Enum.map(fn {chunk, index} ->
          fallback =
            outbox.fallback_visible_text
            |> to_string()
            |> Mrkdwn.from_markdown()
            |> truncate(3_000)

          body = %{
            "channel" => channel_id(outbox.signal_channel_id),
            "text" => fallback,
            "blocks" => chunk
          }

          body =
            if index == 1 and is_binary(outbox.reply_to_source_entry_id),
              do: Map.put(body, "thread_ts", outbox.reply_to_source_entry_id),
              else: body

          %{method: "chat.postMessage", body: body}
        end)

      {:ok, requests}
    end
  end

  def requests_for_outbox(_outbox), do: {:error, :unsupported_outbox_operation}

  defp send_requests(outbox, client) do
    with {:ok, requests} <- requests_for_outbox(outbox) do
      requests
      |> Enum.reduce_while([], fn request, results ->
        case perform(request, client) |> maybe_reply_fallback(request, outbox, client) do
          {:ok, result} -> {:cont, [result | results]}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:error, _reason} = error ->
          error

        results ->
          {:ok, combine_results(Enum.reverse(results)) |> Map.put(:payload, outbox.payload)}
      end
    end
  end

  defp perform(request, client) do
    case SlackOpenAPI.post(client, request.method, body: request.body) do
      {:ok, body} ->
        normalize_success(body)

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
         _outbox,
         client
       )
       when reason in ["thread_not_found", "message_not_found"] do
    SlackOpenAPI.post(client, "chat.postMessage", body: Map.delete(body, "thread_ts"))
    |> case do
      {:ok, result} -> normalize_success(result)
      {:error, _reason} = error -> error
    end
  end

  defp maybe_reply_fallback(result, _request, _outbox, _client), do: result

  defp normalize_success(%{"ts" => ts} = body) do
    {:ok,
     %{
       created_source_entry_id: ts,
       provider_thread_id: get_in(body, ["message", "thread_ts"]),
       raw_payload: body
     }
     |> MapHelpers.compact_map()}
  end

  defp normalize_success(body), do: {:ok, %{raw_payload: body}}

  defp combine_results([result]), do: result

  defp combine_results(results) do
    first = List.first(results) || %{}

    %{
      created_source_entry_id: first[:created_source_entry_id],
      provider_thread_id: first[:provider_thread_id],
      raw_payload: %{"split" => true, "chunks" => Enum.map(results, & &1.raw_payload)}
    }
    |> MapHelpers.compact_map()
  end

  defp send_attachment(outbox, attachment, client) do
    case MapHelpers.optional_text(attachment, "provider_file_id") do
      file_id when is_binary(file_id) ->
        {:ok,
         %{
           raw_payload: %{"ok" => true, "file_id" => file_id, "already_uploaded" => true},
           payload: outbox.payload
         }}

      nil ->
        upload_attachment(outbox, attachment, client)
    end
  end

  defp upload_attachment(outbox, attachment, client) do
    with {:ok, content, name} <- attachment_content(attachment),
         {:ok, body} <-
           SlackOpenAPI.upload_external(client,
             filename: name,
             content: content,
             channel_id: channel_id(outbox.signal_channel_id),
             thread_ts: outbox.reply_to_source_entry_id,
             initial_comment: outbox.fallback_visible_text
           ) do
      payload =
        Map.update(outbox.payload, "attachments", [], fn attachments ->
          Enum.map(attachments, &Map.put(&1, "provider_file_id", first_file_id(body)))
        end)

      {:ok, %{raw_payload: body, payload: payload}}
    end
  end

  defp attachment_content(attachment) do
    relative =
      MapHelpers.optional_text(attachment, "user_files_relative_path") ||
        MapHelpers.optional_text(attachment, "agent_computer_path") ||
        MapHelpers.optional_text(attachment, "path")

    relative =
      if is_binary(relative), do: String.replace_prefix(relative, "/workspace/user-files/", "")

    with relative when is_binary(relative) <- relative,
         {:ok, %{"content" => content}} <-
           WorkerFiles.get("user_files", String.trim_leading(relative, "/")) do
      {:ok, content, MapHelpers.optional_text(attachment, "name") || Path.basename(relative)}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
    end
  end

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

  defp truncate(text, size), do: text |> String.graphemes() |> Enum.take(size) |> Enum.join()

  defp config_for_outbox(outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_chat_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp channel_id("slack:" <> encoded), do: URI.decode(encoded)
  defp channel_id(channel), do: channel
end
