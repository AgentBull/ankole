defmodule Ankole.Plugins.Microsoft365Adapter.Inbound do
  @moduledoc false

  alias Ankole.{Logging, Principals}

  alias Ankole.Plugins.MapHelpers

  alias Ankole.Plugins.Microsoft365Adapter.AdaptiveCard
  alias Ankole.Plugins.Microsoft365Adapter.Config
  alias Ankole.Plugins.Microsoft365Adapter.Conversations
  alias Ankole.Plugins.Microsoft365Adapter.Emoji

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Conversations.{Attachments, Observe}
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
    do: AdapterContext.dispatch_chat(consumers, &emit_message(&1, activity))

  @spec handle_message_removed(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_removed(_event_type, activity, consumers) when is_map(activity),
    do: AdapterContext.dispatch_chat(consumers, &emit_removed(&1, activity))

  @spec handle_reaction_created(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_reaction_created(_event_type, activity, consumers) when is_map(activity),
    do: AdapterContext.dispatch_chat(consumers, &emit_reactions(&1, activity, :add))

  @spec handle_reaction_deleted(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_reaction_deleted(_event_type, activity, consumers) when is_map(activity),
    do: AdapterContext.dispatch_chat(consumers, &emit_reactions(&1, activity, :remove))

  @spec handle_card_action(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, activity, consumers) when is_map(activity),
    do: AdapterContext.dispatch_chat(consumers, &emit_action(&1, activity))

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

    with {:ok, activity_id} <- MapHelpers.required_string(activity, "id"),
         {:ok, conversation_id} <- provider_conversation_id(activity),
         {:ok, attachments} <- attachment_maps(activity, activity_id),
         mentions <- mentions(activity, consumer),
         text <- visible_text(MapHelpers.optional_text(activity, "text"), mentions),
         :ok <- material_message?(text, attachments),
         {:ok, attachments} <- maybe_materialize_attachments(attachments, activity, consumer) do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      thread_root = Conversations.thread_root(conversation_id)
      conversation_type = conversation_type(activity)
      external_id = author_external_id(from)
      namespace = Config.subject_namespace(config)

      author = %{
        "id" => external_id,
        "platform_subject" => external_id,
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
         provider_message_id: activity_id,
         provider_conversation_id: Conversations.conversation_id(base_conversation_id),
         reply_to_provider_message_id: reply_target_id(activity, thread_root, activity_id),
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
               "team_id" => team_id(activity),
               "app_id" => config["appID"]
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
        Observe.emit_entry(consumer.context.binding_id, input)

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
    with {:ok, activity_id} <- MapHelpers.required_string(activity, "id"),
         {:ok, conversation_id} <- provider_conversation_id(activity) do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      thread_root = Conversations.thread_root(conversation_id)

      input = %{
        source_event_id: "deleted:" <> activity_id,
        provider_message_id: activity_id,
        provider_conversation_id: Conversations.conversation_id(base_conversation_id),
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

      Observe.emit_entry_removed(consumer.context.binding_id, input,
        provider_lifecycle_kind: :deleted
      )
    end
  end

  defp emit_reactions(consumer, activity, action) do
    key = if action == :add, do: "reactionsAdded", else: "reactionsRemoved"
    reactions = MapHelpers.fetch_list(activity, key)

    with {:ok, target_id} <- reaction_target(activity),
         {:ok, conversation_id} <- provider_conversation_id(activity) do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      actor = author_external_id(MapHelpers.fetch_map(activity, "from", %{}))

      reactions
      |> Enum.map(fn reaction ->
        raw = MapHelpers.optional_text(reaction, "type") || "unknown"

        Observe.emit_reaction(consumer.context.binding_id, %{
          source_event_id: reaction_event_id(activity, action, target_id, raw, actor),
          provider_conversation_id: Conversations.conversation_id(base_conversation_id),
          provider_message_id: target_id,
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

    with {:ok, activity_id} <- MapHelpers.required_string(activity, "id"),
         {:ok, conversation_id} <- provider_conversation_id(activity),
         true <- is_binary(operator) || :missing_operator do
      base_conversation_id = Conversations.base_conversation_id(conversation_id)
      decoded_value = decode_action_value(value)

      reply_to =
        MapHelpers.optional_text(activity, "replyToId") ||
          reply_surface_entry_id(consumer, decoded_value)

      thread_root = Conversations.thread_root(conversation_id) || reply_to || activity_id

      operator_principal_uid =
        case Ankole.Principals.resolve_platform_subject_uid(
               Config.subject_namespace(consumer.config),
               operator
             ) do
          {:ok, uid} -> uid
          _ -> nil
        end

      Observe.emit_action(consumer.context.binding_id, %{
        source_event_id: activity_id,
        action_id: activity_id,
        provider_conversation_id: Conversations.conversation_id(base_conversation_id),
        provider_message_id: reply_to,
        provider_thread_id: Conversations.provider_thread_id(base_conversation_id, thread_root),
        signal_type: "signal.action.invoked",
        action:
          MapHelpers.compact_map(%{
            "name" => MapHelpers.optional_text(value, "action") || "submit",
            "value" => decoded_value,
            "operator_id" => operator,
            "operator_principal_uid" => operator_principal_uid,
            "provider_message_id" => reply_to
          }),
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

  defp reply_surface_entry_id(consumer, %{"sourceSignalId" => signal_id})
       when is_binary(signal_id) do
    Ankole.Conversations.list_intents!(
      query: [
        filter: [
          agent_uid: consumer.context.agent_uid,
          binding_name: consumer.context.binding_name,
          source_signal_id: signal_id,
          status: :sent,
          created_provider_message_id: [is_nil: false]
        ],
        sort: [inserted_at: :asc],
        limit: 1,
        select: [:created_provider_message_id]
      ]
    )
    |> case do
      [intent] -> intent.created_provider_message_id
      [] -> nil
    end
  end

  defp reply_surface_entry_id(_consumer, _value), do: nil

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

    namespace = Config.subject_namespace(consumer.config)

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
    |> MapHelpers.blank_to_nil()
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

  defp maybe_materialize_attachments(attachments, _activity, %{config: config}) do
    materialized =
      Attachments.materialize_attachments(attachments, "microsoft365", fn attachment ->
        with {:ok, download} <- download_attachment(attachment, config) do
          {:ok, %{body: download.body, filename: download.filename, content_type: nil, put: %{}}}
        end
      end)

    {:ok, materialized}
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

  defp provider_conversation_id(activity) do
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

  defp provider_time(activity),
    do:
      activity
      |> MapHelpers.optional_text("timestamp")
      |> Ankole.Attrs.parse_datetime()
      |> Kernel.||(DateTime.utc_now(:microsecond))

  defp material_message?(nil, []), do: {:ignore, :empty_or_unsupported_message}
  defp material_message?(_text, _attachments), do: :ok
end
