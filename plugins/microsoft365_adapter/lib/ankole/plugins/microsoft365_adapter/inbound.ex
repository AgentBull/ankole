defmodule Ankole.Plugins.Microsoft365Adapter.Inbound do
  @moduledoc false

  alias Ankole.{Logging, Principals, WorkerFiles}

  alias Ankole.Plugins.MapHelpers

  alias Ankole.Plugins.Microsoft365Adapter.{
    AdaptiveCard,
    Config,
    Conversations,
    Emoji
  }

  alias Ankole.SignalsGateway.{AdapterContext, Ingress}
  alias MicrosoftOpenAPI.BotConnector

  @file_download_content_type "application/vnd.microsoft.teams.file.download.info"
  @mention_regex ~r/<at[^>]*>(.*?)<\/at>/s

  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) do
    %{
      kind: :chat,
      context: context,
      config: config
    }
  end

  @spec handle_message_receive(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, activity, consumers) when is_map(activity),
    do: dispatch_chat(consumers, &emit_message(&1, activity))

  @spec handle_message_removed(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_removed(_event_type, activity, consumers) when is_map(activity),
    do: dispatch_chat(consumers, &emit_removed(&1, activity))

  @spec handle_reaction_created(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_reaction_created(_event_type, activity, consumers) when is_map(activity),
    do: dispatch_chat(consumers, &emit_reactions(&1, activity, :add))

  @spec handle_reaction_deleted(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_reaction_deleted(_event_type, activity, consumers) when is_map(activity),
    do: dispatch_chat(consumers, &emit_reactions(&1, activity, :remove))

  @spec handle_card_action(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, activity, consumers) when is_map(activity),
    do: dispatch_chat(consumers, &emit_action(&1, activity))

  @spec normalize_message_receive(map(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(
        activity,
        %{context: %AdapterContext{}, config: config} = consumer
      )
      when is_map(activity) do
    from = MapHelpers.fetch_map(activity, "from", %{})

    cond do
      ignored_sender?(activity, config) ->
        {:ignore, :provider_self_sender}

      is_nil(author_external_id(from)) ->
        {:ignore, :missing_platform_subject}

      true ->
        normalize_supported_message(activity, from, consumer)
    end
  end

  def normalize_message_receive(_activity, _consumer), do: {:error, :invalid_chat_consumer}

  defp normalize_supported_message(activity, from, consumer) do
    config = consumer.config

    with {:ok, activity_id} <- required_text(activity, "id"),
         {:ok, conversation_id} <- conversation_id(activity),
         {:ok, attachments} <- attachment_maps(activity, activity_id),
         mentions <- mentions(activity, consumer),
         text <- visible_text(MapHelpers.optional_text(activity, "text"), mentions),
         :ok <- material_message?(text, attachments),
         {:ok, attachments} <- maybe_materialize_attachments(attachments, activity, consumer) do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      thread_root = Conversations.thread_root(conversation_id)
      conversation_type = conversation_type(activity)
      external_id = author_external_id(from)
      namespace = Config.namespace(config)

      author = %{
        "id" => external_id,
        "platform_subject" => external_id,
        "principal_uid" => String.downcase(external_id),
        "display_name" => MapHelpers.optional_text(from, "name"),
        "metadata" =>
          MapHelpers.compact_map(%{
            "teams_id" => MapHelpers.optional_text(from, "id"),
            "aad_object_id" => MapHelpers.optional_text(from, "aadObjectId"),
            "tenant_id" => tenant_id(activity),
            "provider" => namespace
          })
      }

      {:ok,
       %{
         source_event_id: activity_id,
         source_entry_id: activity_id,
         signal_channel_id: Conversations.signal_channel_id(base_conversation_id),
         reply_to_source_entry_id: reply_target_id(activity, thread_root, activity_id),
         provider_thread_id: Conversations.provider_thread_id(base_conversation_id, thread_root),
         channel: %{
           kind: channel_kind(conversation_type),
           reply_mode: :entry,
           name: channel_name(activity),
           metadata:
             MapHelpers.compact_map(%{
               "conversation_id" => base_conversation_id,
               "conversation_type" => conversation_type,
               "service_url" => MapHelpers.optional_text(activity, "serviceUrl"),
               "tenant_id" => tenant_id(activity),
               "team_id" => team_id(activity)
             }),
           raw_payload:
             MapHelpers.compact_map(MapHelpers.fetch_map(activity, "conversation", %{}))
         },
         text: text,
         formatted_content: if(text, do: %{"format" => "markdown", "body" => text}, else: %{}),
         attachments: attachments,
         mentions: mentions,
         structured_mention_prefixes: Enum.map(mentions, & &1["key"]),
         explicit:
           conversation_type == "personal" or
             Enum.any?(mentions, &(&1["targets_current_agent"] == true)),
         author: author,
         sender_key: String.downcase(external_id),
         metadata:
           MapHelpers.compact_map(%{
             "provider" => "teams",
             "activity_type" => MapHelpers.optional_text(activity, "type"),
             "conversation_type" => conversation_type,
             "tenant_id" => tenant_id(activity),
             "team_id" => team_id(activity)
           }),
         raw_payload: MapHelpers.compact_map(activity),
         provider_time: provider_time(activity)
       }}
    end
  end

  defp emit_message(consumer, activity) do
    case normalize_message_receive(activity, consumer) do
      {:ok, input} ->
        with :ok <- observe_author(consumer, input) do
          Ingress.emit_entry(consumer.context.agent_uid, consumer.context.binding_name, input)
        end

      {:ignore, reason} ->
        {:ok, %{status: :"ignored_#{reason}", reason: reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp reply_target_id(activity, thread_root, activity_id) do
    case MapHelpers.optional_text(activity, "replyToId") do
      reply_to_id when is_binary(reply_to_id) and reply_to_id != activity_id ->
        reply_to_id

      _missing_or_self when is_binary(thread_root) and thread_root != activity_id ->
        thread_root

      _missing_or_self ->
        nil
    end
  end

  defp emit_removed(consumer, activity) do
    with {:ok, activity_id} <- required_text(activity, "id"),
         {:ok, conversation_id} <- conversation_id(activity) do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      thread_root = Conversations.thread_root(conversation_id)

      input = %{
        source_event_id: "deleted:" <> activity_id,
        source_entry_id: activity_id,
        signal_channel_id: Conversations.signal_channel_id(base_conversation_id),
        provider_thread_id: Conversations.provider_thread_id(base_conversation_id, thread_root),
        channel: %{
          kind: channel_kind(conversation_type(activity)),
          reply_mode: :entry,
          raw_payload: MapHelpers.fetch_map(activity, "conversation", %{})
        },
        metadata: %{
          "provider" => "teams",
          "activity_type" => MapHelpers.optional_text(activity, "type")
        },
        raw_payload: activity,
        provider_time: provider_time(activity)
      }

      Ingress.emit_entry_removed(consumer.context.agent_uid, consumer.context.binding_name, input,
        provider_lifecycle_kind: :deleted
      )
    end
  end

  defp emit_reactions(consumer, activity, action) do
    key = if action == :add, do: "reactionsAdded", else: "reactionsRemoved"
    reactions = MapHelpers.fetch_list(activity, key)

    with {:ok, target_id} <- reaction_target(activity),
         {:ok, conversation_id} <- conversation_id(activity) do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      actor = author_external_id(MapHelpers.fetch_map(activity, "from", %{}))

      reactions
      |> Enum.map(fn reaction ->
        raw = MapHelpers.optional_text(reaction, "type") || "unknown"

        Ingress.emit_reaction(consumer.context.agent_uid, consumer.context.binding_name, %{
          source_event_id: reaction_event_id(activity, action, target_id, raw, actor),
          signal_channel_id: Conversations.signal_channel_id(base_conversation_id),
          source_entry_id: target_id,
          reaction_key: Emoji.normalize(raw),
          raw_reaction_key: raw,
          actor_key: actor,
          action: action,
          raw_payload: activity,
          provider_time: provider_time(activity)
        })
      end)
      |> MapHelpers.collect_results()
      |> case do
        {:ok, results} -> {:ok, %{status: :reactions_emitted, results: results}}
        {:error, _reason} = error -> error
      end
    else
      {:error, {:missing, _key}} -> {:ok, %{status: :ignored_missing_reaction_target}}
    end
  end

  defp emit_action(consumer, activity) do
    value = MapHelpers.fetch_map(activity, "value", %{})
    from = MapHelpers.fetch_map(activity, "from", %{})
    operator = author_external_id(from)

    with {:ok, activity_id} <- required_text(activity, "id"),
         {:ok, conversation_id} <- conversation_id(activity),
         true <- is_binary(operator) || :missing_operator do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      reply_to = MapHelpers.optional_text(activity, "replyToId")
      thread_root = Conversations.thread_root(conversation_id) || reply_to || activity_id

      Ingress.emit_action(consumer.context.agent_uid, consumer.context.binding_name, %{
        source_event_id: activity_id,
        action_id: activity_id,
        signal_channel_id: Conversations.signal_channel_id(base_conversation_id),
        source_entry_id: reply_to,
        provider_thread_id: Conversations.provider_thread_id(base_conversation_id, thread_root),
        actor_event_type: "signal.action.invoked",
        action: %{
          "name" => MapHelpers.optional_text(value, "action") || "submit",
          "value" => decode_action_value(value),
          "operator_id" => operator,
          "source_entry_id" => reply_to
        },
        raw_payload: activity
      })
    else
      :missing_operator ->
        Logging.warning(
          "microsoft365_adapter.inbound.action_missing_operator",
          "Teams card action ignored without operator",
          %{activity_id: MapHelpers.optional_text(activity, "id")}
        )

        {:ok, %{status: :ignored_missing_operator}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec card_action?(map()) :: boolean()
  def card_action?(activity) do
    value = MapHelpers.fetch_value(activity, "value")

    is_map(value) and
      MapHelpers.optional_text(value, "v") == AdaptiveCard.action_envelope_version()
  end

  defp decode_action_value(value) do
    case value do
      %{"v" => _version, "value" => decoded} -> decoded
      other -> other
    end
  end

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> MapHelpers.collect_results()
  end

  defp observe_author(consumer, %{author: author}) do
    attrs =
      %{
        provider: Config.namespace(consumer.config),
        external_id: author["platform_subject"],
        uid: author["id"],
        display_name: author["display_name"],
        metadata: author["metadata"] || %{}
      }
      |> MapHelpers.compact_map()

    case AdapterContext.observe_platform_subject(consumer.context, attrs) do
      {:ok, _observed} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # `29:` ids are Teams-encrypted user ids, `28:` ids are bot/connector
  # senders. The bot's own messages echo back with from.id == recipient.id on
  # activities the connector redelivers, but the stable self check is the
  # missing aadObjectId plus the bot id prefix.
  defp ignored_sender?(activity, _config) do
    from = MapHelpers.fetch_map(activity, "from", %{})
    from_id = MapHelpers.optional_text(from, "id") || ""

    recipient_id =
      activity |> MapHelpers.fetch_map("recipient", %{}) |> MapHelpers.optional_text("id")

    String.starts_with?(from_id, "28:") or
      (is_binary(recipient_id) and from_id == recipient_id) or
      MapHelpers.optional_text(from, "role") == "bot"
  end

  defp author_external_id(from) do
    MapHelpers.optional_text(from, "aadObjectId") || MapHelpers.optional_text(from, "id")
  end

  defp mentions(activity, consumer) do
    recipient_id =
      activity |> MapHelpers.fetch_map("recipient", %{}) |> MapHelpers.optional_text("id")

    namespace = Config.namespace(consumer.config)

    activity
    |> MapHelpers.fetch_list("entities")
    |> Enum.filter(&(MapHelpers.optional_text(&1, "type") == "mention"))
    |> Enum.flat_map(fn entity ->
      mentioned = MapHelpers.fetch_map(entity, "mentioned", %{})
      mentioned_id = MapHelpers.optional_text(mentioned, "id")
      key = MapHelpers.optional_text(entity, "text")

      if is_nil(mentioned_id) or is_nil(key) do
        []
      else
        current? = mentioned_id == recipient_id
        subject_id = MapHelpers.optional_text(mentioned, "aadObjectId") || mentioned_id

        [
          %{
            "kind" => if(current?, do: "bot", else: "user"),
            "structured" => true,
            "id" => mentioned_id,
            "key" => key,
            "user_id" => subject_id,
            "name" =>
              mention_name(namespace, subject_id, MapHelpers.optional_text(mentioned, "name")),
            "targets_current_agent" => current?,
            "agent_uid" => if(current?, do: consumer.context.agent_uid)
          }
          |> MapHelpers.compact_map()
        ]
      end
    end)
  end

  defp mention_name(_namespace, _subject_id, name) when is_binary(name), do: "@" <> name

  defp mention_name(namespace, subject_id, nil) do
    with {:ok, uid} <- Principals.resolve_platform_subject_uid(namespace, subject_id),
         {:ok, principal} <- Principals.get_principal(uid),
         name when is_binary(name) <- principal.display_name do
      "@" <> name
    else
      _not_found -> "@" <> subject_id
    end
  end

  defp visible_text(nil, _mentions), do: nil

  defp visible_text(text, mentions) do
    text
    |> strip_current_bot_mentions(mentions)
    |> then(fn visible ->
      Enum.reduce(mentions, visible, fn mention, acc ->
        String.replace(acc, mention["key"], mention["name"])
      end)
    end)
    |> String.replace(@mention_regex, "@\\1")
    |> String.trim_leading()
    |> blank_to_nil()
  end

  defp strip_current_bot_mentions(text, mentions) do
    keys =
      mentions |> Enum.filter(&(&1["targets_current_agent"] == true)) |> Enum.map(& &1["key"])

    text = Enum.reduce(keys, text, &String.replace(&2, &1, ""))
    String.trim_leading(text)
  end

  defp attachment_maps(activity, activity_id) do
    attachments =
      activity
      |> MapHelpers.fetch_list("attachments")
      |> Enum.flat_map(&attachment_map(&1, activity_id))

    {:ok, attachments}
  end

  defp attachment_map(attachment, activity_id) do
    content_type = MapHelpers.optional_text(attachment, "contentType") || ""

    cond do
      content_type == @file_download_content_type ->
        content = MapHelpers.fetch_map(attachment, "content", %{})
        unique_id = MapHelpers.optional_text(content, "uniqueId")
        download_url = MapHelpers.optional_text(content, "downloadUrl")

        if is_binary(download_url) do
          [
            MapHelpers.compact_map(%{
              "provider_ref" => "teams:file:" <> (unique_id || download_url),
              "provider" => "teams",
              "source_message_id" => activity_id,
              "file_id" => unique_id,
              "name" => MapHelpers.optional_text(attachment, "name"),
              "file_type" => MapHelpers.optional_text(content, "fileType"),
              "download_url" => download_url,
              "download_auth" => "none"
            })
          ]
        else
          []
        end

      String.starts_with?(content_type, "image/") ->
        content_url = MapHelpers.optional_text(attachment, "contentUrl")

        if is_binary(content_url) do
          [
            MapHelpers.compact_map(%{
              "provider_ref" => "teams:attachment:" <> content_url,
              "provider" => "teams",
              "source_message_id" => activity_id,
              "name" => MapHelpers.optional_text(attachment, "name"),
              "mimetype" => content_type,
              "download_url" => content_url,
              "download_auth" => "connector"
            })
          ]
        else
          []
        end

      true ->
        # text/html render alternates and card attachments duplicate the text.
        []
    end
  end

  defp maybe_materialize_attachments(attachments, activity, consumer),
    do: materialize_attachments(attachments, activity, consumer)

  defp materialize_attachments(attachments, _activity, %{
         config: config,
         context: %{agent_uid: agent_uid}
       }) do
    {:ok, Enum.map(attachments, &materialize_attachment(&1, config, agent_uid))}
  end

  defp materialize_attachment(attachment, config, agent_uid) do
    with {:ok, download} <- download_attachment(attachment, config),
         relative <- materialized_path(attachment, download.filename),
         lane_path <- Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative),
         {:ok, result} <- WorkerFiles.put("user_files", lane_path, download.body) do
      attachment
      |> Map.put(
        "agent_computer_path",
        Path.join(Ankole.AgentHomePaths.user_files(agent_uid), relative)
      )
      |> Map.put("user_files_relative_path", relative)
      |> MapHelpers.maybe_put("xxh3_128", result["xxh3_128"])
      |> MapHelpers.maybe_put("size", result["size"])
    else
      reason ->
        Logging.warning(
          "microsoft365_adapter.attachment.materialization_skipped",
          "Teams attachment materialization skipped",
          %{provider_ref: attachment["provider_ref"], reason: inspect(reason)}
        )

        attachment
    end
  rescue
    exception ->
      Logging.warning(
        "microsoft365_adapter.attachment.materialization_failed",
        "Teams attachment materialization failed",
        %{provider_ref: attachment["provider_ref"], error: Exception.message(exception)}
      )

      attachment
  end

  defp download_attachment(%{"download_auth" => "connector"} = attachment, config) do
    client = Config.chat_client(config)

    with {:ok, token} <- BotConnector.token(client) do
      MicrosoftOpenAPI.download(attachment["download_url"],
        headers: MicrosoftOpenAPI.bearer_headers(token),
        req_options: client.req_options
      )
    end
  end

  defp download_attachment(attachment, config) do
    MicrosoftOpenAPI.download(attachment["download_url"],
      req_options: Config.chat_client(config).req_options
    )
  end

  defp materialized_path(attachment, downloaded_name) do
    Path.join([
      "inbox",
      "teams",
      sanitize(attachment["source_message_id"]),
      sanitize(attachment["file_id"] || "attachment"),
      sanitize(downloaded_name || attachment["name"] || "attachment")
    ])
  end

  defp sanitize(value) when is_binary(value) do
    case value |> String.replace(~r/[^A-Za-z0-9._-]+/, "_") |> String.trim("_") do
      "" -> "unnamed"
      segment -> String.slice(segment, 0, 160)
    end
  end

  defp sanitize(_value), do: "unnamed"

  defp reaction_target(activity) do
    case MapHelpers.optional_text(activity, "replyToId") ||
           MapHelpers.optional_text(activity, "id") do
      nil -> {:error, {:missing, "replyToId"}}
      target -> {:ok, target}
    end
  end

  defp reaction_event_id(activity, action, target_id, raw, actor) do
    MapHelpers.optional_text(activity, "id") ||
      "reaction:#{action}:#{target_id}:#{raw}:#{actor}"
  end

  defp conversation_id(activity) do
    case activity
         |> MapHelpers.fetch_map("conversation", %{})
         |> MapHelpers.optional_text("id") do
      nil -> {:error, {:missing, "conversation.id"}}
      id -> {:ok, id}
    end
  end

  defp conversation_type(activity) do
    activity
    |> MapHelpers.fetch_map("conversation", %{})
    |> MapHelpers.optional_text("conversationType") || "personal"
  end

  defp channel_kind("personal"), do: :im_dm
  defp channel_kind(_conversation_type), do: :im_group

  defp channel_name(activity) do
    activity
    |> MapHelpers.fetch_map("conversation", %{})
    |> MapHelpers.optional_text("name")
  end

  defp tenant_id(activity) do
    get_in(activity, ["channelData", "tenant", "id"]) ||
      activity
      |> MapHelpers.fetch_map("conversation", %{})
      |> MapHelpers.optional_text("tenantId")
  end

  defp team_id(activity), do: get_in(activity, ["channelData", "team", "id"])

  defp provider_time(activity) do
    case MapHelpers.optional_text(activity, "timestamp") do
      nil ->
        DateTime.utc_now(:microsecond)

      timestamp ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, datetime, _offset} -> datetime
          _error -> DateTime.utc_now(:microsecond)
        end
    end
  end

  defp required_text(map, key) do
    case MapHelpers.optional_text(map, key) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp material_message?(nil, []), do: {:ignore, :empty_or_unsupported_message}
  defp material_message?(_text, _attachments), do: :ok
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
