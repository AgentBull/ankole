defmodule Ankole.Plugins.SlackAdapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.SlackAdapter.{BlockKit, Config, Emoji, ErrorPolicy, Mrkdwn, ReplyPreview}
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{ActorEvent, OutboxEntry}
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias Ankole.WorkerFiles
  alias SlackOpenAPI.Error

  @max_text_chars 12_000

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

    ErrorPolicy.normalize_delivery_result(result)
  end

  def send(%OutboxEntry{} = outbox) do
    result =
      with {:ok, config} <- config_for_outbox(outbox),
           client <- Config.client(config) do
        case MapHelpers.fetch_list(outbox.payload, "attachments") do
          [] -> send_requests(outbox, client)
          [attachment] -> send_attachment(outbox, attachment, client)
          _attachments -> {:error, :multiple_outbound_attachments_not_supported}
        end
      end

    ErrorPolicy.normalize_delivery_result(result)
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
      |> Enum.map(fn text ->
        body = %{
          "channel" => channel_id(outbox.signal_channel_id),
          "text" => Mrkdwn.from_markdown(text)
        }

        body =
          if operation == :reply,
            do: Map.put(body, "thread_ts", outbox.reply_to_source_entry_id),
            else: body

        %{method: "chat.postMessage", body: body, reply?: operation == :reply}
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
        |> Enum.map(fn chunk ->
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
            if is_binary(outbox.reply_to_source_entry_id),
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
         _outbox,
         client
       )
       when reason in ["thread_not_found", "message_not_found"] do
    SlackOpenAPI.post(client, "chat.postMessage", body: Map.delete(body, "thread_ts"))
    |> case do
      {:ok, result} -> normalize_success(result, Map.delete(body, "thread_ts"))
      {:error, _reason} = error -> error
    end
  end

  defp maybe_reply_fallback(result, _request, _outbox, _client), do: result

  defp normalize_success(%{"ts" => ts} = body, request_body) do
    {:ok,
     %{
       created_source_entry_id: ts,
       provider_thread_id: response_thread_id(body, request_body),
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
    with {:ok, content, name} <- attachment_content(attachment, outbox.agent_uid),
         {:ok, body} <-
           SlackOpenAPI.upload_external(client,
             filename: name,
             content: content,
             channel_id: channel_id(outbox.signal_channel_id),
             thread_ts: outbox.reply_to_source_entry_id
           ) do
      payload =
        Map.update(outbox.payload, "attachments", [], fn attachments ->
          Enum.map(attachments, &Map.put(&1, "provider_file_id", first_file_id(body)))
        end)

      {:ok, %{raw_payload: body, payload: payload}}
    end
  end

  defp attachment_content(attachment, agent_uid) do
    relative = MapHelpers.optional_text(attachment, "user_files_relative_path")

    lane_path =
      if is_binary(relative),
        do: Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

    with lane_path when is_binary(lane_path) <- lane_path,
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", lane_path) do
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

  defp truncate(text, size), do: String.slice(text, 0, size)

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
