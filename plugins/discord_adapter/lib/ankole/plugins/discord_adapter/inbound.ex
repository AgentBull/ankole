defmodule Ankole.Plugins.DiscordAdapter.Inbound do
  @moduledoc false

  alias Ankole.{Logging, Principals, WorkerFiles}
  alias Ankole.Plugins.DiscordAdapter.{Client, Config, Emoji}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.{AdapterContext, Entry, Ingress}
  alias Ankole.SignalsGateway.ReplyActionToken

  # Discord serves attachments from its CDN without a documented size ceiling,
  # so this is Ankole's own download budget rather than a provider limit.
  @download_limit_bytes 25 * 1024 * 1024

  @human_message_types [0, 19]

  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{kind: :chat, context: context, config: config}
  end

  @spec handle_message_receive(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_message(&1, event))
  end

  @spec handle_reaction_created(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_reaction_created(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_reaction(&1, event, :add))
  end

  @spec handle_reaction_deleted(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_reaction_deleted(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_reaction(&1, event, :remove))
  end

  @spec handle_card_action(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, event, consumers) do
    dispatch_chat(consumers, &emit_action(&1, event))
  end

  @doc false
  @spec normalize_message_create(map(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_create(
        %{"message" => message, "bot" => bot},
        %{context: %AdapterContext{}} = consumer
      )
      when is_map(message) and is_map(bot) do
    author = map(message, "author")

    if supported_sender?(message, author, bot) do
      normalize_supported_message(message, author, bot, consumer)
    else
      {:ignore, :unsupported_sender}
    end
  end

  def normalize_message_create(_event, _consumer), do: {:error, :invalid_discord_message}

  defp normalize_supported_message(message, author, bot, consumer) do
    with message_id when is_binary(message_id) <- MapHelpers.optional_text(message, "id"),
         user_id when is_binary(user_id) <- MapHelpers.optional_text(author, "id"),
         channel_id when is_binary(channel_id) <- MapHelpers.optional_text(message, "channel_id"),
         attachments <- attachments(message),
         text <- visible_text(message, bot.id),
         true <- material_message?(text, attachments) || {:ignore, :empty_message} do
      guild_id = MapHelpers.optional_text(message, "guild_id")
      channel_kind = if is_nil(guild_id), do: :im_dm, else: :im_group
      signal_channel_id = signal_channel_id(bot.id, channel_id)
      mentioned? = mentions_bot?(message, bot.id)

      {:ok,
       %{
         source_event_id: message_id,
         signal_channel_id: signal_channel_id,
         source_entry_id: message_id,
         reply_to_source_entry_id: referenced_message_id(message),
         provider_thread_id: signal_channel_id,
         channel: %{
           kind: channel_kind,
           reply_mode: :entry,
           metadata:
             MapHelpers.compact_map(%{
               "provider" => "discord",
               "bot_id" => bot.id,
               "channel_id" => channel_id,
               "guild_id" => guild_id
             }),
           raw_payload:
             MapHelpers.compact_map(%{"channel_id" => channel_id, "guild_id" => guild_id})
         },
         text: text,
         formatted_content: %{},
         attachments: attachments,
         mentions: mentions(mentioned?, bot, consumer),
         explicit: channel_kind == :im_dm or mentioned? or reply_to_bot?(message, bot.id),
         author: author(author),
         metadata:
           MapHelpers.compact_map(%{
             "provider" => "discord",
             "channel_id" => channel_id,
             "guild_id" => guild_id
           }),
         raw_payload: message,
         provider_time: iso_time(message["timestamp"])
       }}
    else
      {:ignore, _reason} = ignored -> ignored
      false -> {:ignore, :empty_message}
      _invalid -> {:error, :invalid_discord_message}
    end
  end

  defp emit_message(consumer, event) do
    case normalize_message_create(event, consumer) do
      {:ok, input} -> emit_with_materialization(input, consumer, event)
      {:ignore, reason} -> {:ok, %{status: :ignored, reason: reason}}
      {:error, :invalid_discord_message} -> {:ok, %{status: :ignored, reason: :invalid_message}}
    end
  end

  defp emit_with_materialization(input, consumer, event) do
    if materialization_required?(input.attachments) do
      observed_at = DateTime.utc_now(:microsecond)
      pending = put_materialization_state(input, "pending", observed_at)

      case emit_entry(pending, consumer) do
        {:ok, %{signal_entry: %Entry{attachments: attachments}}} when is_list(attachments) ->
          attachments = materialize_attachments(attachments, consumer, event)

          input
          |> Map.put(:attachments, attachments)
          |> put_materialization_state(materialization_state(attachments), observed_at)
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

  defp emit_reaction(consumer, %{"reaction" => reaction, "bot" => bot} = event, action)
       when is_map(reaction) and is_map(bot) do
    with gateway_session_id when is_binary(gateway_session_id) <-
           MapHelpers.optional_text(event, "gateway_session_id"),
         gateway_sequence when is_integer(gateway_sequence) <- event["gateway_sequence"],
         user_id when is_binary(user_id) <- MapHelpers.optional_text(reaction, "user_id"),
         true <- user_id != bot.id || :ignored_sender,
         message_id when is_binary(message_id) <- MapHelpers.optional_text(reaction, "message_id"),
         channel_id when is_binary(channel_id) <-
           MapHelpers.optional_text(reaction, "channel_id"),
         {reaction_key, raw_key} <- Emoji.reaction_key(map(reaction, "emoji")) do
      Ingress.emit_reaction(consumer.context.agent_uid, consumer.context.binding_name, %{
        source_event_id: "discord:gateway:#{gateway_session_id}:#{gateway_sequence}",
        signal_channel_id: signal_channel_id(bot.id, channel_id),
        source_entry_id: message_id,
        reaction_key: reaction_key,
        raw_reaction_key: raw_key,
        actor_key: user_id,
        action: action
      })
    else
      :ignored_sender -> {:ok, %{status: :ignored_unsupported_sender}}
      _invalid -> {:ok, %{status: :ignored_invalid_reaction}}
    end
  end

  defp emit_reaction(_consumer, _event, _action), do: {:ok, %{status: :ignored_invalid_reaction}}

  # Discord closes an interaction with an error banner if the callback does not
  # arrive within three seconds, so the deferred acknowledgement goes first and
  # the durable ingress follows. A stale token then correctly produces no
  # visible change instead of a second message the agent never authored.
  defp emit_action(consumer, %{"interaction" => interaction, "bot" => bot})
       when is_map(interaction) and is_map(bot) do
    user = interaction_user(interaction)

    with interaction_id when is_binary(interaction_id) <-
           MapHelpers.optional_text(interaction, "id"),
         callback_token when is_binary(callback_token) <-
           MapHelpers.optional_text(interaction, "token"),
         token when is_binary(token) <-
           MapHelpers.optional_text(map(interaction, "data"), "custom_id"),
         message_id when is_binary(message_id) <-
           MapHelpers.optional_text(map(interaction, "message"), "id"),
         channel_id when is_binary(channel_id) <-
           MapHelpers.optional_text(interaction, "channel_id"),
         user_id when is_binary(user_id) <- MapHelpers.optional_text(user, "id"),
         {:ok, principal} <- Principals.resolve_platform_subject("discord", user_id),
         channel <- signal_channel_id(bot.id, channel_id),
         {:ok, value} <-
           ReplyActionToken.resolve(
             token,
             consumer.context.agent_uid,
             consumer.context.binding_name,
             message_id,
             prefix: "dc1"
           ) do
      Ingress.emit_action(consumer.context.agent_uid, consumer.context.binding_name, %{
        source_event_id: interaction_id,
        action_id: interaction_id,
        signal_channel_id: channel,
        source_entry_id: message_id,
        provider_thread_id: channel,
        actor_event_type: "signal.action.invoked",
        action: %{
          "name" => "discord_component",
          "value" => value,
          "operator_id" => user_id,
          "operator_principal_uid" => principal.uid,
          "source_entry_id" => message_id
        },
        raw_payload: %{"interaction_id" => interaction_id}
      })
    else
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
        {:ok, %{status: :ignored_stale_action}}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:ok, %{status: :ignored_invalid_interaction}}
    end
  end

  defp emit_action(_consumer, _event), do: {:ok, %{status: :ignored_invalid_interaction}}

  # A guild interaction carries the clicking human in `member.user`; a DM
  # interaction carries it in `user`.
  defp interaction_user(interaction) do
    case map(map(interaction, "member"), "user") do
      user when map_size(user) > 0 -> user
      _empty -> map(interaction, "user")
    end
  end

  defp mentions(false, _bot, _consumer), do: []

  defp mentions(true, bot, consumer) do
    [
      %{
        "kind" => "bot",
        "structured" => true,
        "id" => bot.id,
        "key" => "<@#{bot.id}>",
        "name" => bot.username || bot.id,
        "targets_current_agent" => true,
        "agent_uid" => consumer.context.agent_uid
      }
    ]
  end

  # Discord renders a mention as `<@id>` inside the content, and the nickname
  # form `<@!id>` still reaches older clients. The visible text drops both so
  # the agent reads the line the human wrote.
  defp visible_text(message, bot_id) do
    message
    |> MapHelpers.optional_text("content")
    |> case do
      nil ->
        nil

      text ->
        text |> String.replace(~r/<@!?#{Regex.escape(bot_id)}>/, " ") |> MapHelpers.presence()
    end
  end

  defp mentions_bot?(message, bot_id) do
    message
    |> MapHelpers.fetch_list("mentions")
    |> Enum.any?(&(MapHelpers.optional_text(&1, "id") == bot_id))
  end

  defp reply_to_bot?(message, bot_id) do
    message
    |> map("referenced_message")
    |> map("author")
    |> MapHelpers.optional_text("id")
    |> Kernel.==(bot_id)
  end

  defp referenced_message_id(message) do
    MapHelpers.optional_text(map(message, "message_reference"), "message_id") ||
      MapHelpers.optional_text(map(message, "referenced_message"), "id")
  end

  # Message type identifies Discord notices; `author.system` only identifies a
  # Discord-owned user. Bots and webhook posts also stay outside user input.
  defp supported_sender?(message, author, bot) do
    id = MapHelpers.optional_text(author, "id")

    message["type"] in @human_message_types and is_binary(id) and id != bot.id and
      Map.get(author, "bot") != true and
      Map.get(author, "system") != true and
      is_nil(MapHelpers.optional_text(message, "webhook_id"))
  end

  defp author(author) do
    id = MapHelpers.optional_text(author, "id")

    %{
      "id" => id,
      "platform_subject" => id,
      "provider" => "discord",
      "display_name" =>
        MapHelpers.optional_text(author, "global_name") ||
          MapHelpers.optional_text(author, "username") || id,
      "metadata" =>
        MapHelpers.compact_map(%{
          "provider" => "discord",
          "username" => MapHelpers.optional_text(author, "username"),
          "global_name" => MapHelpers.optional_text(author, "global_name")
        })
    }
  end

  # Without the message-content intent Discord delivers guild messages that do
  # not mention the bot with empty content and no attachments. There is nothing
  # to project, so the adapter skips them instead of mirroring blank entries.
  defp material_message?(text, attachments), do: is_binary(text) or attachments != []

  defp attachments(message) do
    message
    |> MapHelpers.fetch_list("attachments")
    |> Enum.map(&attachment(&1, MapHelpers.optional_text(message, "id")))
    |> Enum.reject(&is_nil/1)
  end

  defp attachment(%{"id" => id, "url" => url} = attachment, message_id)
       when is_binary(id) and is_binary(url) do
    %{
      "provider" => "discord",
      "provider_ref" => "discord:attachment:#{id}",
      "provider_file_url" => url,
      "source_message_id" => message_id,
      "kind" => "file",
      "name" => MapHelpers.optional_text(attachment, "filename"),
      "mimetype" => MapHelpers.optional_text(attachment, "content_type"),
      "size" => attachment["size"]
    }
    |> MapHelpers.compact_map()
    |> enforce_download_limit()
  end

  defp attachment(_attachment, _message_id), do: nil

  defp enforce_download_limit(%{"size" => size} = attachment)
       when is_integer(size) and size > @download_limit_bytes do
    restricted_attachment(attachment)
  end

  defp enforce_download_limit(attachment), do: attachment

  defp restricted_attachment(attachment) do
    attachment
    |> Map.put("materialization_state", "provider_download_limit")
    |> Map.put("restriction", "Ankole downloads Discord attachments up to 25 MB.")
  end

  defp materialization_required?(attachments) do
    Enum.any?(attachments, fn attachment ->
      is_binary(attachment["provider_file_url"]) and is_nil(attachment["materialization_state"])
    end)
  end

  defp materialize_attachments(attachments, consumer, event) do
    client = client_for(consumer, event)
    Enum.map(attachments, &materialize_attachment(&1, client, consumer.context.agent_uid))
  end

  defp materialize_attachment(%{"materialization_state" => _state} = attachment, _client, _uid),
    do: attachment

  defp materialize_attachment(%{"provider_file_url" => url} = attachment, client, agent_uid) do
    with :ok <- downloadable_size(attachment["size"]),
         {:ok, download} <- Client.download(client, url),
         :ok <- downloadable_size(byte_size(download.body)),
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
      "discord_adapter.attachment.materialization_skipped",
      "Discord attachment materialization skipped",
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

  defp put_materialization_state(input, state, observed_at) do
    %{
      input
      | metadata: Ingress.put_attachment_materialization(input.metadata, state, observed_at)
    }
  end

  defp materialization_state(attachments) do
    if Enum.all?(
         attachments,
         &(&1["materialization_state"] in ["complete", "provider_download_limit"])
       ),
       do: "complete",
       else: "failed"
  end

  @doc false
  @spec signal_channel_id(String.t(), String.t()) :: String.t()
  def signal_channel_id(bot_id, channel_id), do: "discord:#{bot_id}:channel:#{channel_id}"

  defp client_for(_consumer, %{"client" => %Client{} = client}), do: client
  defp client_for(consumer, _event), do: Config.client(consumer.config)

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> MapHelpers.collect_results()
  end

  defp iso_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp iso_time(_value), do: nil

  defp map(container, key) do
    case MapHelpers.fetch_value(container, key) do
      %{} = value -> value
      _missing -> %{}
    end
  end

  defp safe_reason(%Client.Error{} = error),
    do: inspect(%{kind: error.kind, status: error.status})

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "discord_file_unavailable"
end
