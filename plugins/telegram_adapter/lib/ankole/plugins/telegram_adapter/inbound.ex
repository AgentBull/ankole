defmodule Ankole.Plugins.TelegramAdapter.Inbound do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.{Logging, Principals, Repo, WorkerFiles}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.TelegramAdapter.{ActionToken, Client, EntityText}
  alias Ankole.SignalsGateway.{AdapterContext, Entry, Ingress}

  @download_limit_bytes 20 * 1024 * 1024
  @supported_chat_types ["private", "group", "supergroup"]

  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{kind: :chat, context: context, config: config}
  end

  @spec handle_message_receive(String.t(), map(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_message(&1, event))
  end

  @spec handle_reaction_created(String.t(), map(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_reaction_created(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_reactions(&1, event, :add))
  end

  @spec handle_reaction_deleted(String.t(), map(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_reaction_deleted(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_reactions(&1, event, :remove))
  end

  @spec handle_reaction_update(String.t(), map(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_reaction_update(_event_type, event, consumers) do
    dispatch_chat(consumers, fn consumer ->
      with {:ok, removed} <- emit_reactions(consumer, event, :remove),
           {:ok, added} <- emit_reactions(consumer, event, :add) do
        {:ok, %{removed: removed, added: added}}
      end
    end)
  end

  @spec handle_card_action(String.t(), map(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_action(&1, event))
  end

  @doc false
  @spec normalize_message_receive(map(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(
        %{"update_id" => update_id, "message" => message, "bot" => bot},
        %{context: %AdapterContext{}} = consumer
      )
      when is_integer(update_id) and is_map(message) and is_map(bot) do
    from = map(message, "from")
    chat = map(message, "chat")

    cond do
      Map.get(chat, "type") not in @supported_chat_types ->
        {:ignore, :unsupported_chat_type}

      not supported_sender?(message, from) ->
        {:ignore, :unsupported_sender}

      true ->
        normalize_supported_message(update_id, message, from, chat, bot, consumer)
    end
  end

  def normalize_message_receive(_event, _consumer), do: {:error, :invalid_telegram_message}

  defp normalize_supported_message(update_id, message, from, chat, bot, consumer) do
    with message_id when is_integer(message_id) <- Map.get(message, "message_id"),
         user_id when is_integer(user_id) <- Map.get(from, "id"),
         chat_id when is_integer(chat_id) <- Map.get(chat, "id"),
         {text, entities} <- message_text(message),
         attachments <- attachments(message, message_id),
         true <- material_message?(text, attachments, message) || {:ignore, :empty_message} do
      channel_kind = if chat["type"] == "private", do: :im_dm, else: :im_group

      signal_channel_id =
        signal_channel_id(bot.id, chat_id, Map.get(message, "message_thread_id"))

      entity_projection = project_entities(text, entities, bot, consumer)
      text = visible_text(text, entity_projection, message)

      explicit =
        channel_kind == :im_dm or entity_projection.explicit? or reply_to_bot?(message, bot.id)

      {:ok,
       %{
         source_event_id: Integer.to_string(update_id),
         signal_channel_id: signal_channel_id,
         source_entry_id: Integer.to_string(message_id),
         reply_to_source_entry_id:
           nested_integer_text(message, ["reply_to_message", "message_id"]),
         provider_thread_id: signal_channel_id,
         channel: %{
           kind: channel_kind,
           reply_mode: :entry,
           name: chat_name(chat),
           metadata:
             MapHelpers.compact_map(%{
               "provider" => "telegram",
               "bot_id" => bot.id,
               "chat_id" => Integer.to_string(chat_id),
               "chat_type" => chat["type"],
               "message_thread_id" => integer_text(message["message_thread_id"]),
               "is_forum" => chat["is_forum"] == true
             }),
           raw_payload:
             MapHelpers.compact_map(
               Map.take(chat, ["id", "type", "title", "username", "is_forum"])
             )
         },
         text: text,
         formatted_content: %{},
         attachments: attachments,
         mentions: entity_projection.mentions,
         structured_mention_prefixes: entity_projection.command_prefixes,
         explicit: explicit,
         author: author(from),
         metadata:
           MapHelpers.compact_map(%{
             "provider" => "telegram",
             "update_id" => update_id,
             "message_thread_id" => message["message_thread_id"],
             "media_group_id" => message["media_group_id"]
           }),
         raw_payload: message,
         provider_time: unix_time(message["date"])
       }}
    else
      {:ignore, _reason} = ignored -> ignored
      false -> {:ignore, :empty_message}
      _invalid -> {:error, :invalid_telegram_message}
    end
  end

  defp emit_message(consumer, event) do
    case normalize_message_receive(event, consumer) do
      {:ok, input} -> emit_with_materialization(input, consumer)
      {:ignore, reason} -> {:ok, %{status: :ignored, reason: reason}}
      {:error, _reason} = error -> error
    end
  end

  defp emit_with_materialization(input, consumer) do
    if materialization_required?(input.attachments) do
      pending = put_materialization_state(input, "pending")

      case emit_entry(pending, consumer) do
        {:ok, %{signal_entry: %Entry{attachments: attachments}}}
        when is_list(attachments) ->
          attachments = materialize_attachments(attachments, consumer)

          input
          |> Map.put(:attachments, attachments)
          |> put_materialization_state(materialization_state(attachments))
          |> emit_entry(consumer)

        {:ok, _held_or_ignored} = result ->
          result

        {:error, _reason} = error ->
          error
      end
    else
      emit_entry(input, consumer)
    end
  end

  defp emit_entry(input, consumer) do
    Ingress.emit_entry(consumer.context.agent_uid, consumer.context.binding_name, input)
  end

  defp emit_reactions(consumer, %{"update_id" => update_id} = event, action) do
    reaction = map(event, "message_reaction")
    user = map(reaction, "user")
    chat = map(reaction, "chat")
    bot = map(event, "bot")

    with true <- supported_sender?(reaction, user) || :ignored_sender,
         message_id when is_integer(message_id) <- reaction["message_id"],
         chat_id when is_integer(chat_id) <- chat["id"],
         user_id when is_integer(user_id) <- user["id"] do
      old = Map.get(reaction, "old_reaction") || []
      new = Map.get(reaction, "new_reaction") || []

      changed =
        if action == :add, do: reaction_difference(new, old), else: reaction_difference(old, new)

      channel_id =
        reaction_channel_id(
          consumer.context,
          bot.id,
          chat_id,
          Integer.to_string(message_id)
        )

      changed
      |> Enum.map(fn item ->
        {reaction_key, raw_key} = reaction_key(item)

        Ingress.emit_reaction(consumer.context.agent_uid, consumer.context.binding_name, %{
          source_event_id: "#{update_id}:#{action}:#{reaction_key}:#{user_id}",
          signal_channel_id: channel_id,
          source_entry_id: Integer.to_string(message_id),
          reaction_key: reaction_key,
          raw_reaction_key: raw_key,
          actor_key: Integer.to_string(user_id),
          action: action,
          provider_time: unix_time(reaction["date"])
        })
      end)
      |> MapHelpers.collect_results()
    else
      :ignored_sender -> {:ok, %{status: :ignored_unsupported_sender}}
      _invalid -> {:ok, %{status: :ignored_invalid_reaction}}
    end
  end

  defp emit_action(consumer, %{"update_id" => update_id} = event) do
    callback = map(event, "callback_query")
    from = map(callback, "from")
    message = map(callback, "message")
    chat = map(message, "chat")
    bot = map(event, "bot")

    with true <- supported_sender?(callback, from) || :ignored_sender,
         callback_id when is_binary(callback_id) <- MapHelpers.presence(callback["id"]),
         token when is_binary(token) <- MapHelpers.presence(callback["data"]),
         message_id when is_integer(message_id) <- message["message_id"],
         chat_id when is_integer(chat_id) <- chat["id"],
         user_id when is_integer(user_id) <- from["id"],
         {:ok, principal} <-
           Principals.resolve_platform_subject("telegram", Integer.to_string(user_id)),
         channel_id <- signal_channel_id(bot.id, chat_id, message["message_thread_id"]),
         {:ok, value} <-
           ActionToken.resolve(
             token,
             consumer.context.agent_uid,
             consumer.context.binding_name,
             Integer.to_string(message_id)
           ),
         {:ok, _action_result} = result <-
           Ingress.emit_action(consumer.context.agent_uid, consumer.context.binding_name, %{
             source_event_id: Integer.to_string(update_id),
             action_id: callback_id,
             signal_channel_id: channel_id,
             source_entry_id: Integer.to_string(message_id),
             provider_thread_id: channel_id,
             actor_event_type: "signal.action.invoked",
             action: %{
               "name" => "telegram_callback",
               "value" => value,
               "operator_id" => Integer.to_string(user_id),
               "operator_principal_uid" => principal.uid,
               "source_entry_id" => Integer.to_string(message_id)
             },
             raw_payload: %{"update_id" => update_id, "callback_query_id" => callback_id}
           }) do
      acknowledge_callback(event, callback_id)
      result
    else
      :ignored_sender ->
        {:ok, %{status: :ignored_unsupported_sender}}

      {:error, :not_found} ->
        {:ok, %{status: :ignored_unmapped_operator}}

      {:error, reason}
      when reason in [
             :invalid_callback_token,
             :callback_source_not_found,
             :callback_binding_mismatch,
             :callback_message_mismatch,
             :invalid_callback_action
           ] ->
        acknowledge_callback(event, callback["id"], "This action is no longer available.")
        {:ok, %{status: :ignored_stale_action}}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:ok, %{status: :ignored_invalid_callback}}
    end
  end

  defp acknowledge_callback(event, callback_id, message \\ nil)

  defp acknowledge_callback(%{"client" => %Client{} = client}, callback_id, message)
       when is_binary(callback_id) do
    body = MapHelpers.compact_map(%{"callback_query_id" => callback_id, "text" => message})
    _result = Client.call(client, "answerCallbackQuery", body)
    :ok
  end

  defp acknowledge_callback(_event, _callback_id, _message), do: :ok

  defp message_text(message) do
    cond do
      is_binary(message["text"]) ->
        {message["text"], Map.get(message, "entities") || []}

      is_binary(message["caption"]) ->
        {message["caption"], Map.get(message, "caption_entities") || []}

      true ->
        {nil, []}
    end
  end

  defp project_entities(nil, _entities, _bot, _consumer),
    do: %{mentions: [], command_prefixes: [], replacements: [], explicit?: false}

  defp project_entities(text, entities, bot, consumer) when is_list(entities) do
    username = MapHelpers.presence(bot.username)

    Enum.reduce(
      entities,
      %{mentions: [], command_prefixes: [], replacements: [], explicit?: false},
      fn
        %{"type" => type} = entity, acc when type in ["mention", "bot_command"] ->
          value = EntityText.value(text, entity)

          cond do
            type == "mention" and bot_mention?(value, username) ->
              mention = %{
                "kind" => "bot",
                "structured" => true,
                "id" => bot.id,
                "key" => value,
                "name" => value,
                "targets_current_agent" => true,
                "agent_uid" => consumer.context.agent_uid
              }

              %{
                acc
                | mentions: [mention | acc.mentions],
                  replacements: [{entity["offset"], entity["length"], ""} | acc.replacements],
                  explicit?: true
              }

            type == "bot_command" and addressed_command?(value, username) ->
              normalized = normalize_addressed_command(value, username)

              %{
                acc
                | command_prefixes: [value | acc.command_prefixes],
                  replacements: [
                    {entity["offset"], entity["length"], normalized} | acc.replacements
                  ],
                  explicit?: true
              }

            true ->
              acc
          end

        _entity, acc ->
          acc
      end
    )
    |> then(fn projection ->
      %{
        projection
        | mentions: Enum.reverse(projection.mentions),
          command_prefixes: Enum.reverse(projection.command_prefixes),
          replacements: Enum.reverse(projection.replacements)
      }
    end)
  end

  defp project_entities(_text, _entities, _bot, _consumer),
    do: %{mentions: [], command_prefixes: [], replacements: [], explicit?: false}

  defp visible_text(text, projection, message) do
    base = text || supplemental_text(message)

    if is_binary(base) and projection.replacements != [] do
      base |> EntityText.splice(projection.replacements) |> blank_to_nil()
    else
      blank_to_nil(base)
    end
  end

  defp supplemental_text(%{"location" => %{} = location}) do
    "Location: #{location["latitude"]}, #{location["longitude"]}"
  end

  defp supplemental_text(%{"contact" => %{} = contact}) do
    [contact["first_name"], contact["last_name"], contact["phone_number"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> then(&"Contact: #{&1}")
  end

  defp supplemental_text(%{"poll" => %{} = poll}), do: "Poll: #{poll["question"]}"
  defp supplemental_text(_message), do: nil

  defp attachments(message, message_id) do
    [
      photo_attachment(message, message_id),
      media_attachment(message, message_id, "document"),
      media_attachment(message, message_id, "audio"),
      media_attachment(message, message_id, "voice"),
      media_attachment(message, message_id, "video"),
      media_attachment(message, message_id, "video_note"),
      media_attachment(message, message_id, "animation"),
      media_attachment(message, message_id, "sticker")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp photo_attachment(%{"photo" => photos}, message_id) when is_list(photos) do
    photos
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(
      fn photo ->
        {
          numeric_metric(photo["file_size"]),
          numeric_metric(photo["width"]) * numeric_metric(photo["height"])
        }
      end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      photo -> attachment(photo, message_id, "photo", "photo.jpg", "image/jpeg")
    end
  end

  defp photo_attachment(_message, _message_id), do: nil

  defp media_attachment(message, message_id, kind) do
    case Map.get(message, kind) do
      %{} = media ->
        attachment(
          media,
          message_id,
          kind,
          media["file_name"] || default_filename(kind, media),
          media["mime_type"]
        )

      _missing ->
        nil
    end
  end

  defp attachment(%{"file_id" => file_id} = media, message_id, kind, name, mimetype)
       when is_binary(file_id) do
    %{
      "provider" => "telegram",
      "provider_ref" => "telegram:file:#{media["file_unique_id"] || file_id}",
      "provider_file_id" => file_id,
      "source_message_id" => Integer.to_string(message_id),
      "kind" => kind,
      "name" => name,
      "mimetype" => mimetype,
      "size" => media["file_size"]
    }
    |> MapHelpers.compact_map()
    |> enforce_download_limit()
  end

  defp attachment(_media, _message_id, _kind, _name, _mimetype), do: nil

  defp enforce_download_limit(%{"size" => size} = attachment)
       when is_integer(size) and size > @download_limit_bytes do
    restricted_attachment(attachment)
  end

  defp enforce_download_limit(attachment), do: attachment

  defp restricted_attachment(attachment) do
    attachment
    |> Map.put("materialization_state", "provider_download_limit")
    |> Map.put("restriction", "Telegram Bot API cloud file download limit is 20 MB.")
  end

  defp materialization_required?(attachments) do
    Enum.any?(attachments, fn attachment ->
      is_binary(attachment["provider_file_id"]) and is_nil(attachment["materialization_state"])
    end)
  end

  defp materialize_attachments(attachments, consumer) do
    client = Ankole.Plugins.TelegramAdapter.Config.client(consumer.config)
    Enum.map(attachments, &materialize_attachment(&1, client, consumer.context.agent_uid))
  end

  defp materialize_attachment(
         %{"materialization_state" => _state} = attachment,
         _client,
         _agent_uid
       ),
       do: attachment

  defp materialize_attachment(%{"provider_file_id" => file_id} = attachment, client, agent_uid) do
    with {:ok, file} when is_map(file) <- Client.call(client, "getFile", %{"file_id" => file_id}),
         :ok <- downloadable_size(file["file_size"] || attachment["size"]),
         file_path when is_binary(file_path) <- file["file_path"],
         {:ok, download} <- Client.download(client, file_path),
         relative <- materialized_relative_path(attachment, download.filename),
         lane_path <- Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative),
         {:ok, result} <- WorkerFiles.put("user_files", lane_path, download.body) do
      attachment
      |> Map.put("materialization_state", "complete")
      |> Map.put(
        "agent_computer_path",
        Path.join(Ankole.AgentHomePaths.user_files(agent_uid), relative)
      )
      |> Map.put("user_files_relative_path", relative)
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

  defp materialization_failed(attachment, reason) do
    Logging.warning(
      "telegram_adapter.attachment.materialization_skipped",
      "Telegram attachment materialization skipped",
      %{provider_ref: attachment["provider_ref"], reason: safe_reason(reason)}
    )

    Map.put(attachment, "materialization_state", "failed")
  end

  defp downloadable_size(size) when is_integer(size) and size > @download_limit_bytes,
    do: {:error, :provider_download_limit}

  defp downloadable_size(_size), do: :ok

  defp materialized_relative_path(attachment, downloaded_name) do
    Path.join([
      "inbox",
      Integer.to_string(attachment["attachment_id"]),
      WorkerFiles.sanitize_path_segment(attachment["name"] || downloaded_name || "attachment")
    ])
  end

  defp put_materialization_state(input, state) do
    metadata = Map.put(input.metadata, "attachment_materialization", %{"state" => state})
    %{input | metadata: metadata}
  end

  defp materialization_state(attachments) do
    if Enum.all?(
         attachments,
         &(&1["materialization_state"] in ["complete", "provider_download_limit"])
       ),
       do: "complete",
       else: "failed"
  end

  defp author(from) do
    id = Integer.to_string(from["id"])

    %{
      "id" => id,
      "platform_subject" => id,
      "provider" => "telegram",
      "display_name" => display_name(from, id),
      "metadata" =>
        MapHelpers.compact_map(%{
          "provider" => "telegram",
          "username" => from["username"],
          "first_name" => from["first_name"],
          "last_name" => from["last_name"],
          "language_code" => from["language_code"]
        })
    }
  end

  defp display_name(from, id) do
    [from["first_name"], from["last_name"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" ")
    |> case do
      "" -> if(is_binary(from["username"]), do: "@#{from["username"]}", else: id)
      name -> name
    end
  end

  defp supported_sender?(container, from) do
    is_map(from) and is_integer(from["id"]) and from["is_bot"] != true and
      from["is_guest"] != true and from["is_anonymous"] != true and
      is_nil(container["sender_chat"]) and is_nil(container["business_connection_id"]) and
      is_nil(container["sender_business_bot"]) and is_nil(container["via_bot"])
  end

  defp reply_to_bot?(message, bot_id) do
    reply_from = get_in(message, ["reply_to_message", "from"])
    is_map(reply_from) and integer_text(reply_from["id"]) == to_string(bot_id)
  end

  defp bot_mention?(value, username) when is_binary(value) and is_binary(username),
    do: String.downcase(value) == "@#{String.downcase(username)}"

  defp bot_mention?(_value, _username), do: false

  defp addressed_command?(value, username) when is_binary(value) and is_binary(username) do
    String.downcase(value) |> String.ends_with?("@#{String.downcase(username)}")
  end

  defp addressed_command?(_value, _username), do: false

  defp normalize_addressed_command(value, username) do
    suffix = "@#{username}"
    String.slice(value, 0, String.length(value) - String.length(suffix))
  end

  defp reaction_difference(left, right) do
    right_counts = Enum.frequencies_by(right, &reaction_identity/1)

    {result, _counts} =
      Enum.reduce(left, {[], right_counts}, fn item, {items, counts} ->
        key = reaction_identity(item)

        case Map.get(counts, key, 0) do
          count when count > 0 -> {items, Map.put(counts, key, count - 1)}
          _missing -> {[item | items], counts}
        end
      end)

    Enum.reverse(result)
  end

  defp reaction_identity(%{"type" => "emoji", "emoji" => emoji}), do: {:emoji, emoji}

  defp reaction_identity(%{"type" => "custom_emoji", "custom_emoji_id" => id}),
    do: {:custom_emoji, id}

  defp reaction_identity(reaction), do: {:unknown, inspect(reaction)}

  defp reaction_key(%{"type" => "emoji", "emoji" => emoji}), do: {emoji, emoji}

  defp reaction_key(%{"type" => "custom_emoji", "custom_emoji_id" => id}),
    do: {"telegram_custom:#{id}", id}

  defp reaction_key(reaction), do: {"telegram_unknown", inspect(reaction)}

  # A reaction update carries no topic id, so the lookup finds the channel the
  # message entry recorded. The chat match is exact or `:topic:`-delimited: a
  # bare prefix would also match another chat whose id extends this one, for
  # example `-1001234` behind `-100123`.
  defp reaction_channel_id(context, bot_id, chat_id, source_entry_id) do
    base = signal_channel_id(bot_id, chat_id, nil)

    Entry
    |> where(
      [entry],
      entry.source_entry_id == ^source_entry_id and
        (entry.signal_channel_id == ^base or
           like(entry.signal_channel_id, ^"#{base}:topic:%"))
    )
    |> limit(1)
    |> Repo.one()
    |> case do
      %Entry{signal_channel_id: channel_id} -> channel_id
      nil -> base
    end
  rescue
    exception ->
      Logging.warning(
        "telegram_adapter.reaction.channel_lookup_failed",
        "Telegram reaction channel lookup failed",
        %{binding: context.binding_name, reason: Exception.message(exception)}
      )

      signal_channel_id(bot_id, chat_id, nil)
  end

  @doc false
  @spec signal_channel_id(String.t(), integer(), integer() | nil) :: String.t()
  def signal_channel_id(bot_id, chat_id, topic_id) do
    base = "telegram:#{bot_id}:chat:#{chat_id}"
    if is_integer(topic_id), do: "#{base}:topic:#{topic_id}", else: base
  end

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> MapHelpers.collect_results()
  end

  defp material_message?(text, attachments, message) do
    is_binary(blank_to_nil(text)) or attachments != [] or is_map(message["location"]) or
      is_map(message["contact"]) or is_map(message["poll"])
  end

  defp chat_name(chat),
    do: MapHelpers.presence(chat["title"]) || MapHelpers.presence(chat["username"])

  defp default_filename("voice", _media), do: "voice.ogg"
  defp default_filename("video_note", _media), do: "video-note.mp4"
  defp default_filename("sticker", %{"is_animated" => true}), do: "sticker.tgs"
  defp default_filename("sticker", %{"is_video" => true}), do: "sticker.webm"
  defp default_filename("sticker", _media), do: "sticker.webp"
  defp default_filename(kind, _media), do: kind

  defp unix_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      _invalid -> nil
    end
  end

  defp unix_time(_value), do: nil

  defp nested_integer_text(map, path), do: map |> get_in(path) |> integer_text()
  defp numeric_metric(value) when is_integer(value) and value >= 0, do: value
  defp numeric_metric(_value), do: 0
  defp integer_text(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_text(value) when is_binary(value) and value != "", do: value
  defp integer_text(_value), do: nil

  defp map(container, key) do
    case Map.get(container, key) do
      %{} = value -> value
      _missing -> %{}
    end
  end

  defp blank_to_nil(value) when is_binary(value), do: MapHelpers.presence(value)
  defp blank_to_nil(value), do: value

  defp safe_reason(%Client.Error{} = error),
    do: inspect(%{kind: error.kind, error_code: error.error_code})

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "telegram_file_unavailable"
end
