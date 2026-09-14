defmodule Ankole.Plugins.LineAdapter.Inbound do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.{Logging, Principals, Repo, WorkerFiles}
  alias Ankole.Plugins.LineAdapter.{Client, Config, Presentation}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.UTF16Text
  alias Ankole.SignalsGateway.{AdapterContext, Entry, Ingress, OutboxEntry, Projection}
  alias Ankole.SignalsGateway.ReplyActionToken

  @download_limit_bytes 25 * 1024 * 1024
  @transcoding_polls 10
  @transcoding_poll_interval_ms 1_000
  @source_types ["user", "group", "room"]
  @media_types ["image", "video", "audio", "file"]
  @message_types ["text", "sticker", "location" | @media_types]
  @terminal_attachment_states ["complete", "provider_download_limit", "provider_external_content"]
  @provider_fact_states ["provider_download_limit", "provider_external_content"]

  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{kind: :chat, context: context, config: config}
  end

  @spec handle_message_receive(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, envelope, consumers) do
    dispatch_chat(consumers, &emit_message(&1, envelope))
  end

  @spec handle_message_removed(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_removed(_event_type, envelope, consumers) do
    dispatch_chat(consumers, &emit_removed(&1, envelope))
  end

  @spec handle_card_action(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, envelope, consumers) do
    dispatch_chat(consumers, &emit_action(&1, envelope))
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
      signal_channel_id = Presentation.signal_channel_id(bot_user_id, chat.type, chat.id)
      quoted_message_id = MapHelpers.presence(message["quotedMessageId"])

      # LINE has no threads. A group chat is the channel, and a quote is the
      # only reply relation, carried by `reply_to_source_entry_id`. Naming the
      # chat as a provider thread would make every quote in a group where the
      # Agent once wrote count as a reply to the Agent.

      explicit =
        channel_kind == :im_dm or projection.explicit? or
          bot_authored?(consumer, quoted_message_id)

      {:ok,
       %{
         source_event_id: event_id,
         signal_channel_id: signal_channel_id,
         source_entry_id: message_id,
         reply_to_source_entry_id: quoted_message_id,
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

  # The pending observation is durable before the webhook returns 200; the
  # download runs after, so LINE does not time out and redeliver the batch
  # while Ankole fetches a large file.
  defp emit_with_materialization(input, consumer) do
    {input, observed_at} = reuse_materialized_attachments(input, consumer)

    if materialization_required?(input.attachments) do
      pending = put_materialization_state(input, "pending", observed_at)

      case emit_entry(pending, consumer) do
        {:ok, %{signal_entry: %Entry{attachments: attachments}}} = result
        when is_list(attachments) ->
          start_materialization(input, attachments, consumer, observed_at)
          result

        {:ok, _held_or_ignored} = result ->
          result

        {:error, _reason} = error ->
          error
      end
    else
      emit_entry(input, consumer)
    end
  end

  # LINE redelivers a batch after a non-2xx answer, and the redelivered event
  # names the same media. A result this Agent already holds stays, together
  # with the observation anchor of the first sighting. Everything else is
  # fetched again, including a download whose earlier task never finished: the
  # adapter has no proof that such a task is alive, and the gateway keeps a
  # stored readable path under its entry lock, so a second download that
  # overlaps the first cannot lose the file. A copy that another Agent
  # downloaded does not count; each Agent holds its own copy.
  defp reuse_materialized_attachments(%{attachments: []} = input, _consumer),
    do: {input, DateTime.utc_now(:microsecond)}

  defp reuse_materialized_attachments(input, consumer) do
    case Repo.get_by(Entry,
           signal_channel_id: input.signal_channel_id,
           source_entry_id: input.source_entry_id
         ) do
      %Entry{attachments: stored, metadata: stored_metadata}
      when is_list(stored) and stored != [] ->
        by_ref = Map.new(stored, &{&1["provider_ref"], &1})
        agent_uid = consumer.context.agent_uid

        attachments =
          Enum.map(input.attachments, fn attachment ->
            case Map.get(by_ref, attachment["provider_ref"]) do
              %{"materialization_state" => "complete"} = kept ->
                if Projection.materialized_attachment?(agent_uid, kept),
                  do: kept,
                  else: attachment

              %{"materialization_state" => state} = kept when state in @provider_fact_states ->
                kept

              _missing_failed_or_unfinished ->
                attachment
            end
          end)

        observation = stored_metadata["attachment_materialization"]

        metadata =
          if is_map(observation),
            do: Map.put(input.metadata, "attachment_materialization", observation),
            else: input.metadata

        {%{input | attachments: attachments, metadata: metadata}, observed_at(observation)}

      _no_mirror ->
        {input, DateTime.utc_now(:microsecond)}
    end
  rescue
    exception ->
      Logging.warning(
        "line_adapter.attachment.reuse_lookup_failed",
        "LINE attachment reuse lookup failed",
        %{source_entry_id: input.source_entry_id, reason: Exception.message(exception)}
      )

      {input, DateTime.utc_now(:microsecond)}
  end

  # The anchor stays the first sighting, so a fetched-again attachment does not
  # move the batch window of an event the gateway already accepted.
  defp observed_at(%{"observed_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> observed_at
      _invalid -> DateTime.utc_now(:microsecond)
    end
  end

  defp observed_at(_observation), do: DateTime.utc_now(:microsecond)

  defp start_materialization(input, attachments, consumer, observed_at) do
    work = fn -> materialize_and_emit(input, attachments, consumer, observed_at) end

    case Task.Supervisor.start_child(
           Ankole.Plugins.LineAdapter.MaterializationTaskSupervisor,
           work
         ) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> work.()
    end
  end

  defp materialize_and_emit(input, attachments, consumer, observed_at) do
    attachments = materialize_attachments(attachments, consumer)

    input
    |> Map.put(:attachments, attachments)
    |> put_materialization_state(materialization_state(attachments), observed_at)
    |> emit_entry(consumer)
    |> case do
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

  defp emit_entry(input, consumer) do
    Ingress.emit_entry(consumer.context.agent_uid, consumer.context.binding_name, input)
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
      signal_channel_id = Presentation.signal_channel_id(bot_user_id, chat.type, chat.id)

      Ingress.emit_entry_removed(
        consumer.context.agent_uid,
        consumer.context.binding_name,
        %{
          source_event_id: event_id,
          source_entry_id: message_id,
          signal_channel_id: signal_channel_id,
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

  # A postback names no message, so the token binds to the ActorEvent, the
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
           ReplyActionToken.resolve(
             token,
             consumer.context.agent_uid,
             consumer.context.binding_name,
             nil,
             prefix: "ln1"
           ),
         {:ok, surface_entry_id} <- reply_surface_entry_id(consumer, value),
         signal_channel_id <- Presentation.signal_channel_id(bot_user_id, chat.type, chat.id),
         {:ok, _action_result} = result <-
           Ingress.emit_action(consumer.context.agent_uid, consumer.context.binding_name, %{
             source_event_id: event_id,
             action_id: event_id,
             signal_channel_id: signal_channel_id,
             source_entry_id: surface_entry_id,
             provider_thread_id: nil,
             actor_event_type: "signal.action.invoked",
             action: %{
               "name" => "line_postback",
               "value" => value,
               "operator_id" => user_id,
               "operator_principal_uid" => principal.uid,
               "source_entry_id" => surface_entry_id
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

  defp materialization_required?(attachments) do
    Enum.any?(attachments, fn attachment ->
      is_binary(attachment["provider_file_id"]) and is_nil(attachment["materialization_state"])
    end)
  end

  defp materialize_attachments(attachments, consumer) do
    client = Config.client(consumer.config)
    Enum.map(attachments, &materialize_attachment(&1, client, consumer.context.agent_uid))
  end

  defp materialize_attachment(
         %{"materialization_state" => _state} = attachment,
         _client,
         _agent_uid
       ),
       do: attachment

  defp materialize_attachment(
         %{"provider_file_id" => message_id} = attachment,
         client,
         agent_uid
       ) do
    with :ok <- wait_for_transcoding(client, attachment),
         {:ok, download} <- Client.download(client, message_id, @download_limit_bytes),
         name <- materialized_name(attachment, download.content_type),
         relative <- materialized_relative_path(attachment, name),
         lane_path <- Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative),
         {:ok, result} <- WorkerFiles.put("user_files", lane_path, download.body) do
      attachment
      |> Map.put("materialization_state", "complete")
      |> Map.put("name", name)
      |> Map.put(
        "agent_computer_path",
        Path.join(Ankole.AgentHomePaths.user_files(agent_uid), relative)
      )
      |> Map.put("user_files_relative_path", relative)
      |> MapHelpers.put_present("mimetype", download.content_type)
      |> MapHelpers.put_present("xxh3_128", result["xxh3_128"])
      |> MapHelpers.put_present("size", result["size"])
    else
      {:error, :provider_download_limit} -> restricted_attachment(attachment)
      reason -> materialization_failed(attachment, reason)
    end
  rescue
    exception -> materialization_failed(attachment, exception)
  end

  defp materialize_attachment(attachment, _client, _agent_uid), do: attachment

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

  defp materialization_failed(attachment, reason) do
    Logging.warning(
      "line_adapter.attachment.materialization_skipped",
      "LINE attachment materialization skipped",
      %{provider_ref: attachment["provider_ref"], reason: safe_reason(reason)}
    )

    Map.put(attachment, "materialization_state", "failed")
  end

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

  defp materialized_relative_path(attachment, name) do
    Path.join([
      "inbox",
      Integer.to_string(attachment["attachment_id"]),
      WorkerFiles.sanitize_path_segment(name || "attachment")
    ])
  end

  defp put_materialization_state(input, state, observed_at) do
    %{
      input
      | metadata: Ingress.put_attachment_materialization(input.metadata, state, observed_at)
    }
  end

  defp materialization_state(attachments) do
    if Enum.all?(attachments, &(&1["materialization_state"] in @terminal_attachment_states)),
      do: "complete",
      else: "failed"
  end

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

  # The postback names no message. The durable outbox row that carried the
  # buttons for this ActorEvent names the provider entry the gateway accepted
  # as the reply surface; without it the buttons were never delivered.
  defp reply_surface_entry_id(consumer, %{"sourceActorEventId" => actor_event_id})
       when is_binary(actor_event_id) do
    OutboxEntry
    |> where(
      [outbox],
      outbox.agent_uid == ^consumer.context.agent_uid and
        outbox.binding_name == ^consumer.context.binding_name and
        outbox.source_actor_event_id == ^actor_event_id and
        outbox.status == :succeeded and not is_nil(outbox.created_source_entry_id)
    )
    |> order_by([outbox], asc: outbox.inserted_at)
    |> limit(1)
    |> select([outbox], outbox.created_source_entry_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :reply_surface_not_sent}
      source_entry_id -> {:ok, source_entry_id}
    end
  end

  defp reply_surface_entry_id(_consumer, _value), do: {:error, :reply_surface_not_sent}

  # A quoted message from the bot makes the group message explicit, like a
  # reply to the bot elsewhere. The webhook does not name the quoted author,
  # so the durable outbox record of what Ankole sent answers the question. A
  # long reply is several LINE messages; the row names the first one as its
  # created entry and keeps every sent id in its payload.
  defp bot_authored?(_consumer, nil), do: false

  defp bot_authored?(consumer, quoted_message_id) do
    OutboxEntry
    |> where(
      [outbox],
      outbox.agent_uid == ^consumer.context.agent_uid and
        outbox.binding_name == ^consumer.context.binding_name and
        (outbox.created_source_entry_id == ^quoted_message_id or
           fragment(
             "(? -> 'line_message_ids') @> to_jsonb(?::text)",
             outbox.payload,
             ^quoted_message_id
           ))
    )
    |> Repo.exists?()
  rescue
    exception ->
      Logging.warning(
        "line_adapter.inbound.quote_lookup_failed",
        "LINE quoted message lookup failed",
        %{binding: consumer.context.binding_name, reason: Exception.message(exception)}
      )

      false
  end

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> MapHelpers.collect_results()
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

  defp safe_reason(%Client.Error{} = error),
    do: inspect(%{kind: error.kind, status: error.status})

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({:error, reason}), do: safe_reason(reason)
  defp safe_reason(_reason), do: "line_content_unavailable"
end
