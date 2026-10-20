defmodule Ankole.Plugins.LineAdapter.Inbound do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.{Logging, Principals, Repo}
  alias Ankole.Plugins.LineAdapter.Client
  alias Ankole.Plugins.LineAdapter.Config
  alias Ankole.Plugins.LineAdapter.Presentation
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.UTF16Text
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Conversations.{Attachments, Observe}
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.ActionToken

  @download_limit_bytes 25 * 1024 * 1024
  @transcoding_polls 10
  @transcoding_poll_interval_ms 1_000
  @source_types ["user", "group", "room"]
  @media_types ["image", "video", "audio", "file"]
  @message_types ["text", "sticker", "location" | @media_types]
  @provider_fact_states ["provider_download_limit", "provider_external_content"]

  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{kind: :chat, context: context, config: config}
  end

  @spec handle_message_receive(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, envelope, consumers) do
    AdapterContext.dispatch_chat(consumers, &emit_message(&1, envelope))
  end

  @spec handle_message_removed(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_removed(_event_type, envelope, consumers) do
    AdapterContext.dispatch_chat(consumers, &emit_removed(&1, envelope))
  end

  @spec handle_card_action(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, envelope, consumers) do
    AdapterContext.dispatch_chat(consumers, &emit_action(&1, envelope))
  end

  @doc false
  @spec normalize_message_receive(map(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(
        %{"destination" => bot_user_id, "event" => %{"type" => "message"} = event},
        %{context: %AdapterContext{}} = consumer
      )
      when is_binary(bot_user_id) do
    source = map(event, "source")
    message = map(event, "message")

    cond do
      event["mode"] == "standby" -> {:ignore, :standby_mode}
      source["type"] not in @source_types -> {:ignore, :unsupported_source_type}
      is_nil(MapHelpers.presence(source["userId"])) -> {:ignore, :missing_user_id}
      message["type"] not in @message_types -> {:ignore, :unsupported_message_type}
      true -> normalize_supported_message(bot_user_id, event, source, message, consumer)
    end
  end

  def normalize_message_receive(_envelope, _consumer), do: {:error, :invalid_line_event}

  defp normalize_supported_message(bot_user_id, event, source, message, consumer) do
    with event_id when is_binary(event_id) <- MapHelpers.presence(event["webhookEventId"]),
         message_id when is_binary(message_id) <- MapHelpers.presence(message["id"]),
         {:ok, chat} <- chat(source),
         projection <- project_text(message, bot_user_id, consumer),
         attachments <- attachments(message),
         true <- material_message?(projection.text, attachments) || {:ignore, :empty_message} do
      channel_kind = if chat.type == "user", do: :im_dm, else: :im_group
      conversation_id = Presentation.conversation_id(bot_user_id, chat.type, chat.id)
      quoted_message_id = MapHelpers.presence(message["quotedMessageId"])

      # LINE has no threads. A group chat is the channel, and a quote is the
      # only reply relation, carried by `reply_to_provider_message_id`. Naming the
      # chat as a provider thread would make every quote in a group where the
      # Agent once wrote count as a reply to the Agent.

      explicit =
        channel_kind == :im_dm or projection.explicit? or
          bot_authored?(consumer, quoted_message_id)

      {:ok,
       %{
         source_event_id: event_id,
         provider_conversation_id: conversation_id,
         provider_message_id: message_id,
         reply_to_provider_message_id: quoted_message_id,
         provider_thread_id: nil,
         channel: %{
           kind: channel_kind,
           reply_mode: :entry,
           name: nil,
           metadata:
             MapHelpers.compact_map(%{
               "provider" => "line",
               "bot_user_id" => bot_user_id,
               "chat_type" => chat.type,
               "chat_id" => chat.id
             }),
           raw_payload: source
         },
         text: projection.text,
         formatted_content: %{},
         attachments: attachments,
         mentions: projection.mentions,
         structured_mention_prefixes: [],
         explicit: explicit,
         author: author(source),
         metadata:
           MapHelpers.compact_map(%{
             "provider" => "line",
             "webhook_event_id" => event_id,
             "is_redelivery" => get_in(event, ["deliveryContext", "isRedelivery"]) == true,
             "message_type" => message["type"],
             "quote_token" => MapHelpers.presence(message["quoteToken"])
           }),
         raw_payload: event,
         provider_time: unix_millis(event["timestamp"])
       }}
    else
      {:ignore, _reason} = ignored -> ignored
      _invalid -> {:error, :invalid_line_event}
    end
  end

  defp emit_message(consumer, envelope) do
    case normalize_message_receive(envelope, consumer) do
      {:ok, input} -> emit_with_materialization(input, consumer)
      {:ignore, reason} -> {:ok, %{status: :ignored, reason: reason}}
      {:error, :invalid_line_event} -> {:ok, %{status: :ignored, reason: :invalid_event}}
    end
  end

  defp emit_with_materialization(input, consumer) do
    Observe.emit_entry_deferred(
      input,
      &emit_entry(&1, consumer),
      &materialize_attachments(&1, consumer),
      &start_materialization(&1, consumer),
      @provider_fact_states
    )
  end

  defp start_materialization(task, consumer) do
    Task.Supervisor.start_child(
      Ankole.Plugins.LineAdapter.MaterializationTaskSupervisor,
      fn ->
        case task.() do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logging.warning(
              "line_adapter.attachment.materialization_emit_failed",
              "LINE attachment observation could not be stored",
              %{binding: consumer.context.binding_name, reason: inspect(reason)}
            )

            :ok
        end
      end
    )
  end

  defp emit_entry(input, consumer) do
    Observe.emit_entry(consumer.context.agent_uid, consumer.context.binding_name, input)
  end

  defp emit_removed(consumer, %{
         "destination" => bot_user_id,
         "event" => %{"type" => "unsend"} = event
       })
       when is_binary(bot_user_id) do
    source = map(event, "source")

    with false <- event["mode"] == "standby",
         event_id when is_binary(event_id) <- MapHelpers.presence(event["webhookEventId"]),
         message_id when is_binary(message_id) <-
           MapHelpers.presence(get_in(event, ["unsend", "messageId"])),
         {:ok, chat} <- chat(source) do
      conversation_id = Presentation.conversation_id(bot_user_id, chat.type, chat.id)

      Observe.emit_entry_removed(
        consumer.context.agent_uid,
        consumer.context.binding_name,
        %{
          source_event_id: event_id,
          provider_message_id: message_id,
          provider_conversation_id: conversation_id,
          provider_thread_id: nil,
          channel: %{
            kind: if(chat.type == "user", do: :im_dm, else: :im_group),
            reply_mode: :entry,
            raw_payload: source
          },
          metadata: %{"provider" => "line", "webhook_event_id" => event_id},
          raw_payload: event,
          provider_time: unix_millis(event["timestamp"])
        },
        provider_lifecycle_kind: :unsent
      )
    else
      true -> {:ok, %{status: :ignored, reason: :standby_mode}}
      _invalid -> {:ok, %{status: :ignored_invalid_unsend}}
    end
  end

  defp emit_removed(_consumer, _envelope), do: {:ok, %{status: :ignored_invalid_unsend}}

  # A postback names no message, so the token binds to the Signal, the
  # binding, and the action fingerprint. A stale token produces no visible
  # change, which is the right outcome for an action the reply already replaced.
  defp emit_action(
         consumer,
         %{"destination" => bot_user_id, "event" => %{"type" => "postback"} = event}
       )
       when is_binary(bot_user_id) do
    source = map(event, "source")

    with false <- event["mode"] == "standby",
         event_id when is_binary(event_id) <- MapHelpers.presence(event["webhookEventId"]),
         user_id when is_binary(user_id) <- MapHelpers.presence(source["userId"]),
         token when is_binary(token) <- MapHelpers.presence(get_in(event, ["postback", "data"])),
         {:ok, chat} <- chat(source),
         {:ok, principal} <- Principals.resolve_platform_subject("line", user_id),
         {:ok, value} <-
           ActionToken.resolve(
             token,
             consumer.context.agent_uid,
             consumer.context.binding_name,
             nil,
             prefix: "ln1"
           ),
         {:ok, surface_entry_id} <- reply_surface_entry_id(consumer, value),
         conversation_id <- Presentation.conversation_id(bot_user_id, chat.type, chat.id),
         {:ok, _action_result} = result <-
           Observe.emit_action(consumer.context.agent_uid, consumer.context.binding_name, %{
             source_event_id: event_id,
             action_id: event_id,
             provider_conversation_id: conversation_id,
             provider_message_id: surface_entry_id,
             provider_thread_id: nil,
             signal_type: "signal.action.invoked",
             action: %{
               "name" => "line_postback",
               "value" => value,
               "operator_id" => user_id,
               "operator_principal_uid" => principal.uid,
               "provider_message_id" => surface_entry_id
             },
             raw_payload: %{"webhook_event_id" => event_id, "postback" => event["postback"]}
           }) do
      result
    else
      true ->
        {:ok, %{status: :ignored, reason: :standby_mode}}

      {:error, :not_found} ->
        {:ok, %{status: :ignored_unmapped_operator}}

      {:error, :reply_surface_not_sent} ->
        {:ok, %{status: :ignored_stale_action}}

      {:error, reason}
      when reason in [
             :invalid_callback_token,
             :callback_source_not_found,
             :callback_binding_mismatch,
             :callback_message_mismatch,
             :invalid_callback_action
           ] ->
        {:ok, %{status: :ignored_stale_action}}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:ok, %{status: :ignored_invalid_postback}}
    end
  end

  defp emit_action(_consumer, _envelope), do: {:ok, %{status: :ignored_invalid_postback}}

  defp chat(source) do
    case source["type"] do
      "user" -> chat_id("user", source["userId"])
      "group" -> chat_id("group", source["groupId"])
      "room" -> chat_id("room", source["roomId"])
      _other -> {:error, :unsupported_source_type}
    end
  end

  defp chat_id(type, id) do
    case MapHelpers.presence(id) do
      nil -> {:error, :missing_chat_id}
      id -> {:ok, %{type: type, id: id}}
    end
  end

  # A mention of the bot is a structured mention. Its `index` and `length` are
  # UTF-16 code units, like every LINE character count.
  defp project_text(%{"type" => "text"} = message, bot_user_id, consumer) do
    text = message["text"]

    self_mentions =
      message
      |> get_in(["mention", "mentionees"])
      |> List.wrap()
      |> Enum.filter(fn mentionee ->
        is_map(mentionee) and mentionee["isSelf"] == true and
          is_integer(mentionee["index"]) and is_integer(mentionee["length"])
      end)

    mentions =
      Enum.map(self_mentions, fn mentionee ->
        key = UTF16Text.slice(text, mentionee["index"], mentionee["length"]) || "@"

        %{
          "kind" => "bot",
          "structured" => true,
          "id" => bot_user_id,
          "key" => key,
          "name" => key,
          "targets_current_agent" => true,
          "agent_uid" => consumer.context.agent_uid
        }
      end)

    replacements = Enum.map(self_mentions, &{&1["index"], &1["length"], ""})

    visible =
      if is_binary(text) and replacements != [],
        do: UTF16Text.splice(text, replacements),
        else: text

    %{text: blank_to_nil(visible), mentions: mentions, explicit?: self_mentions != []}
  end

  defp project_text(message, _bot_user_id, _consumer),
    do: %{text: supplemental_text(message), mentions: [], explicit?: false}

  defp supplemental_text(%{"type" => "sticker"} = message) do
    "Sticker: #{message["packageId"]}/#{message["stickerId"]}"
  end

  defp supplemental_text(%{"type" => "location"} = message) do
    [message["title"], message["address"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.concat(["#{message["latitude"]}, #{message["longitude"]}"])
    |> Enum.join(" ")
    |> then(&"Location: #{&1}")
  end

  defp supplemental_text(_message), do: nil

  defp attachments(%{"type" => type, "id" => message_id} = message)
       when type in @media_types and is_binary(message_id) do
    provider = map(message, "contentProvider")

    %{
      "provider" => "line",
      "provider_ref" => "line:message:#{message_id}",
      "source_message_id" => message_id,
      "kind" => type,
      "name" => MapHelpers.presence(message["fileName"]) || "#{type}-#{message_id}",
      "size" => message["fileSize"]
    }
    |> MapHelpers.compact_map()
    |> put_content_source(provider, message_id)
    |> enforce_download_limit()
    |> List.wrap()
  end

  defp attachments(_message), do: []

  # Content from another service arrives as a URL that LINE does not host, so
  # the Agent gets the reference instead of a download.
  defp put_content_source(attachment, %{"type" => "external"} = provider, _message_id) do
    attachment
    |> Map.put("materialization_state", "provider_external_content")
    |> Map.put("restriction", "LINE does not host this content; the provider URL is recorded.")
    |> MapHelpers.put_present("url", MapHelpers.presence(provider["originalContentUrl"]))
  end

  defp put_content_source(attachment, _provider, message_id),
    do: Map.put(attachment, "provider_file_id", message_id)

  defp enforce_download_limit(%{"size" => size} = attachment)
       when is_integer(size) and size > @download_limit_bytes,
       do: restricted_attachment(attachment)

  defp enforce_download_limit(attachment), do: attachment

  defp restricted_attachment(attachment) do
    attachment
    |> Map.put("materialization_state", "provider_download_limit")
    |> Map.put("restriction", "Ankole downloads LINE content up to 25 MB.")
  end

  defp materialize_attachments(attachments, consumer) do
    client = Config.client(consumer.config)

    Attachments.materialize_attachments(attachments, "line", &download_attachment(&1, client),
      restriction: "Ankole downloads LINE content up to 25 MB."
    )
  end

  defp download_attachment(%{"provider_file_id" => message_id} = attachment, client) do
    with :ok <- wait_for_transcoding(client, attachment),
         {:ok, download} <- Client.download(client, message_id, @download_limit_bytes) do
      name = materialized_name(attachment, download.content_type)
      put = MapHelpers.put_present(%{"name" => name}, "mimetype", download.content_type)
      {:ok, %{body: download.body, filename: nil, content_type: nil, put: put}}
    end
  end

  defp download_attachment(_attachment, _client), do: {:error, :attachment_reference_missing}

  # A video or audio message from the LINE app is transcoded before its bytes
  # can be read. The wait is bounded; the attachment fails after it.
  defp wait_for_transcoding(client, %{"kind" => kind, "provider_file_id" => message_id})
       when kind in ["video", "audio"] do
    Enum.reduce_while(1..@transcoding_polls, {:error, :transcoding_timeout}, fn attempt, _acc ->
      case Client.transcoding_status(client, message_id) do
        {:ok, "succeeded"} ->
          {:halt, :ok}

        {:ok, "processing"} when attempt < @transcoding_polls ->
          Process.sleep(@transcoding_poll_interval_ms)
          {:cont, {:error, :transcoding_timeout}}

        {:ok, "processing"} ->
          {:halt, {:error, :transcoding_timeout}}

        {:ok, _failed} ->
          {:halt, {:error, :transcoding_failed}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp wait_for_transcoding(_client, _attachment), do: :ok

  defp materialized_name(%{"kind" => "file"} = attachment, _content_type),
    do: attachment["name"]

  defp materialized_name(attachment, content_type) do
    case extension(content_type) do
      nil -> attachment["name"]
      extension -> attachment["name"] <> "." <> extension
    end
  end

  defp extension("image/jpeg"), do: "jpg"
  defp extension("image/png"), do: "png"
  defp extension("image/gif"), do: "gif"
  defp extension("video/mp4"), do: "mp4"
  defp extension("audio/mp4"), do: "m4a"
  defp extension("audio/x-m4a"), do: "m4a"
  defp extension("audio/m4a"), do: "m4a"
  defp extension("audio/mpeg"), do: "mp3"
  defp extension(_content_type), do: nil

  # A LINE event carries only the sender's user id, so the author has no
  # display name here. A matched Principal supplies its own name, and the
  # Profile hydrator fills the blank for an unmatched sender.
  defp author(source) do
    user_id = source["userId"]

    %{
      "id" => user_id,
      "platform_subject" => user_id,
      "provider" => "line",
      "metadata" =>
        MapHelpers.compact_map(%{
          "provider" => "line",
          "group_id" => MapHelpers.presence(source["groupId"]),
          "room_id" => MapHelpers.presence(source["roomId"])
        })
    }
  end

  # The postback names no message. The durable intent row that carried the
  # buttons for this Signal names the provider entry the gateway accepted
  # as the reply surface; without it the buttons were never delivered.
  defp reply_surface_entry_id(consumer, %{"sourceSignalId" => signal_id})
       when is_binary(signal_id) do
    Intent
    |> where(
      [intent],
      intent.agent_uid == ^consumer.context.agent_uid and
        intent.binding_name == ^consumer.context.binding_name and
        intent.source_signal_id == ^signal_id and
        intent.status == :sent and not is_nil(intent.created_provider_message_id)
    )
    |> order_by([intent], asc: intent.inserted_at)
    |> limit(1)
    |> select([intent], intent.created_provider_message_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :reply_surface_not_sent}
      provider_message_id -> {:ok, provider_message_id}
    end
  end

  defp reply_surface_entry_id(_consumer, _value), do: {:error, :reply_surface_not_sent}

  # A quoted message from the bot makes the group message explicit, like a
  # reply to the bot elsewhere. The webhook does not name the quoted author,
  # so the durable intent record of what Ankole sent answers the question. A
  # long reply is several LINE messages; the row names the first one as its
  # created entry and keeps every sent id in its payload.
  defp bot_authored?(_consumer, nil), do: false

  defp bot_authored?(consumer, quoted_message_id) do
    Intent
    |> where(
      [intent],
      intent.agent_uid == ^consumer.context.agent_uid and
        intent.binding_name == ^consumer.context.binding_name and
        (intent.created_provider_message_id == ^quoted_message_id or
           fragment(
             "(? -> 'line_message_ids') @> to_jsonb(?::text)",
             intent.payload,
             ^quoted_message_id
           ))
    )
    |> Repo.exists?()
  end

  defp material_message?(text, attachments), do: is_binary(text) or attachments != []

  defp unix_millis(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      _invalid -> nil
    end
  end

  defp unix_millis(_value), do: nil

  defp map(container, key) do
    case Map.get(container, key) do
      %{} = value -> value
      _missing -> %{}
    end
  end

  defp blank_to_nil(value) when is_binary(value), do: MapHelpers.presence(value)
  defp blank_to_nil(value), do: value
end
