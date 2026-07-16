defmodule Ankole.Plugins.SlackAdapter.Inbound do
  @moduledoc false

  alias Ankole.{Logging, Principals, SignalsGateway, WorkerFiles}
  alias Ankole.Plugins.SlackAdapter.{Channels, Config, Emoji, MapHelpers}
  alias Ankole.SignalsGateway.{AdapterContext, Ingress}
  alias SlackOpenAPI.Event

  @mention_regex ~r/<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/
  @recent_attachment_window_seconds 120
  @max_backfilled_attachments 3

  @spec chat_consumer(AdapterContext.t(), map(), keyword()) :: map()
  def chat_consumer(%AdapterContext{} = context, config, opts \\ []) do
    %{
      kind: :chat,
      context: context,
      config: config,
      recent_attachment_window_seconds:
        Keyword.get(opts, :recent_attachment_window_seconds, @recent_attachment_window_seconds),
      max_backfilled_attachments:
        Keyword.get(opts, :max_backfilled_attachments, @max_backfilled_attachments),
      materialize_attachments: Keyword.get(opts, :materialize_attachments, false),
      attachment_materializer:
        Keyword.get(opts, :attachment_materializer, &materialize_attachments/3)
    }
  end

  @spec handle_message_receive(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(
        _event_type,
        %Event{content: %{"subtype" => "message_deleted"}} = event,
        consumers
      ),
      do: handle_message_removed("message", event, consumers)

  def handle_message_receive(
        _event_type,
        %Event{content: %{"subtype" => "message_changed"}},
        consumers
      ),
      do: ignored_for_chat(consumers, :ignored_message_changed)

  def handle_message_receive(_event_type, %Event{} = event, consumers) do
    result = dispatch_chat(consumers, &emit_message(&1, event))
    maybe_log_missing_sender(event, result)
    result
  end

  @spec handle_message_removed(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_removed(_event_type, %Event{} = event, consumers),
    do: dispatch_chat(consumers, &emit_removed(&1, event))

  @spec handle_reaction_created(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_reaction_created(_event_type, %Event{} = event, consumers),
    do: dispatch_chat(consumers, &emit_reaction(&1, event, :add))

  @spec handle_reaction_deleted(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_reaction_deleted(_event_type, %Event{} = event, consumers),
    do: dispatch_chat(consumers, &emit_reaction(&1, event, :remove))

  @spec handle_card_action(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, %Event{} = event, consumers),
    do: dispatch_chat(consumers, &emit_action(&1, event))

  @spec normalize_message_receive(Event.t(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(
        %Event{} = event,
        %{context: %AdapterContext{}, config: config} = consumer
      ) do
    message = event.content || %{}
    subtype = MapHelpers.optional_text(message, "subtype")
    user_id = MapHelpers.optional_text(message, "user")

    cond do
      ignored_sender?(message, config) ->
        {:ignore, :provider_self_sender}

      is_nil(user_id) ->
        {:ignore, :missing_platform_subject}

      subtype not in [nil, "file_share", "thread_broadcast"] ->
        {:ignore, :empty_or_unsupported_message}

      true ->
        normalize_supported_message(event, message, user_id, consumer)
    end
  end

  def normalize_message_receive(_event, _consumer), do: {:error, :invalid_chat_consumer}

  defp normalize_supported_message(event, message, user_id, consumer) do
    config = consumer.config

    with {:ok, source_entry_id} <- required_text(message, "ts"),
         {:ok, slack_channel_id} <- required_text(message, "channel"),
         {:ok, attachments} <- attachment_maps(message, source_entry_id),
         mentions <- mentions(Map.get(message, "text", ""), consumer),
         text <- visible_text(Map.get(message, "text"), mentions),
         :ok <- material_message?(text, attachments),
         provider_time <- provider_time(source_entry_id, event),
         attachments <-
           maybe_backfill_attachments(
             attachments,
             text,
             mentions,
             user_id,
             slack_channel_id,
             provider_time,
             consumer
           ),
         {:ok, attachments} <- maybe_materialize_attachments(attachments, message, consumer) do
      channel_kind = channel_kind(message)
      namespace = Map.get(config, "platformSubjectNamespace", "slack-main")
      signal_channel_id = signal_channel_id(slack_channel_id)

      author = %{
        "id" => user_id,
        "platform_subject" => user_id,
        "principal_uid" => String.downcase(user_id),
        "metadata" =>
          MapHelpers.compact_map(%{"team_id" => event.team_id, "provider" => namespace})
      }

      {:ok,
       %{
         source_event_id: event.id || source_entry_id,
         source_entry_id: source_entry_id,
         signal_channel_id: signal_channel_id,
         reply_to_source_entry_id: reply_target_id(message, source_entry_id),
         provider_thread_id: message_thread_id(slack_channel_id, message),
         channel: %{
           kind: channel_kind,
           reply_mode: :entry,
           name: nil,
           metadata:
             MapHelpers.compact_map(%{
               "channel_id" => slack_channel_id,
               "channel_type" => Map.get(message, "channel_type"),
               "team_id" => event.team_id,
               "api_app_id" => event.api_app_id
             }),
           raw_payload: MapHelpers.compact_map(message)
         },
         text: text,
         formatted_content: if(text, do: %{"format" => "markdown", "body" => text}, else: %{}),
         attachments: attachments,
         mentions: mentions,
         structured_mention_prefixes: Enum.map(mentions, & &1["key"]),
         explicit:
           channel_kind == :im_dm or Enum.any?(mentions, &(&1["targets_current_agent"] == true)),
         author: author,
         sender_key: String.downcase(user_id),
         metadata:
           MapHelpers.compact_map(%{
             "provider" => "slack",
             "event_type" => event.type,
             "subtype" => Map.get(message, "subtype"),
             "team_id" => event.team_id
           }),
         raw_payload: MapHelpers.compact_map(event.raw || %{}),
         provider_time: provider_time
       }}
    end
  end

  defp emit_message(consumer, event) do
    case normalize_message_receive(event, consumer) do
      {:ok, input} ->
        with :ok <- observe_author(consumer, input),
             result <-
               Ingress.emit_entry(
                 consumer.context.agent_uid,
                 consumer.context.binding_name,
                 input
               ) do
          if match?({:ok, _}, result),
            do: Channels.maybe_enqueue_missing_channel_refresh(consumer, input)

          result
        end

      {:ignore, reason} ->
        {:ok, %{status: ignored_status(reason), reason: reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp emit_removed(consumer, event) do
    message = event.content || %{}

    with {:ok, source_entry_id} <- required_text(message, "deleted_ts"),
         {:ok, slack_channel_id} <- required_text(message, "channel") do
      input = %{
        source_event_id: event.id || "deleted:#{source_entry_id}",
        source_entry_id: source_entry_id,
        signal_channel_id: signal_channel_id(slack_channel_id),
        provider_thread_id:
          message_thread_id(slack_channel_id, Map.get(message, "previous_message") || %{}),
        channel: %{kind: channel_kind(message), reply_mode: :entry, raw_payload: message},
        metadata: %{"provider" => "slack", "event_type" => event.type},
        raw_payload: event.raw || %{},
        provider_time: provider_time(source_entry_id, event)
      }

      Ingress.emit_entry_removed(consumer.context.agent_uid, consumer.context.binding_name, input,
        provider_lifecycle_kind: :deleted
      )
    end
  end

  defp emit_reaction(consumer, event, action) do
    content = event.content || %{}
    item = MapHelpers.fetch_map(content, "item", %{})

    cond do
      Map.get(item, "type") != "message" ->
        {:ok, %{status: :ignored_unsupported_reaction_target}}

      true ->
        with {:ok, user_id} <- required_text(content, "user"),
             {:ok, source_entry_id} <- required_text(item, "ts"),
             {:ok, channel} <- required_text(item, "channel"),
             {:ok, reaction} <- required_text(content, "reaction") do
          raw = String.replace(reaction, ~r/::skin-tone-\d+$/, "")

          Ingress.emit_reaction(consumer.context.agent_uid, consumer.context.binding_name, %{
            source_event_id: event.id || "reaction:#{action}:#{source_entry_id}:#{user_id}",
            signal_channel_id: signal_channel_id(channel),
            source_entry_id: source_entry_id,
            reaction_key: Emoji.normalize(raw),
            raw_reaction_key: raw,
            actor_key: user_id,
            action: action,
            raw_payload: event.raw || %{},
            provider_time: event.created_at
          })
        end
    end
  end

  defp emit_action(consumer, event) do
    payload = event.content || %{}
    action = payload |> MapHelpers.fetch_list("actions") |> List.first() || %{}
    user_id = get_in(payload, ["user", "id"])
    channel = get_in(payload, ["container", "channel_id"]) || get_in(payload, ["channel", "id"])

    message_ts =
      get_in(payload, ["container", "message_ts"]) || get_in(payload, ["message", "ts"])

    with true <- is_binary(user_id) || :missing_operator,
         true <- is_binary(channel) || :missing_channel,
         action_id when is_binary(action_id) <- event.id || Map.get(action, "action_ts") do
      Ingress.emit_action(consumer.context.agent_uid, consumer.context.binding_name, %{
        source_event_id: action_id,
        action_id: action_id,
        signal_channel_id: signal_channel_id(channel),
        source_entry_id: message_ts,
        provider_thread_id: provider_thread_id(channel, message_ts || action_id),
        actor_event_type: "signal.action.invoked",
        action: %{
          "name" => Map.get(action, "action_id"),
          "value" => decode_action_value(Map.get(action, "value")),
          "operator_id" => user_id,
          "source_entry_id" => message_ts
        },
        raw_payload: event.raw || %{}
      })
    else
      :missing_operator ->
        Logging.warning(
          "slack_adapter.inbound.action_missing_operator",
          "Slack action ignored without operator",
          %{event_id: event.id}
        )

        {:ok, %{status: :ignored_missing_operator}}

      :missing_channel ->
        {:ok, %{status: :ignored_missing_channel}}

      nil ->
        {:ok, %{status: :ignored_missing_action_id}}
    end
  end

  defp decode_action_value(value) when is_binary(value) do
    case Torque.decode(value) do
      {:ok, %{"v" => "ankole.interactive_output.action.v1", "value" => decoded}} -> decoded
      _other -> value
    end
  end

  defp decode_action_value(value), do: value

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> MapHelpers.collect_results()
  end

  defp ignored_for_chat(consumers, status) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fn _consumer -> {:ok, %{status: status}} end)
    |> MapHelpers.collect_results()
  end

  defp observe_author(consumer, %{author: author}) do
    attrs =
      %{
        provider: Map.get(consumer.config, "platformSubjectNamespace", "slack-main"),
        external_id: author["platform_subject"],
        uid: author["id"],
        metadata: author["metadata"] || %{}
      }
      |> MapHelpers.compact_map()

    case AdapterContext.observe_platform_subject(consumer.context, attrs) do
      {:ok, _observed} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ignored_sender?(message, config) do
    user_id = Map.get(message, "user")

    bot_ids =
      [Map.get(config, "runtimeBotUserID"), Map.get(config, "botUserID")]
      |> Enum.reject(&is_nil/1)

    Map.get(message, "subtype") == "bot_message" or
      is_binary(Map.get(message, "bot_id")) or
      (is_binary(user_id) and user_id in bot_ids)
  end

  defp mentions(text, consumer) when is_binary(text) do
    namespace = Map.get(consumer.config, "platformSubjectNamespace", "slack-main")

    bot_ids =
      [Map.get(consumer.config, "runtimeBotUserID"), Map.get(consumer.config, "botUserID")]
      |> Enum.reject(&is_nil/1)

    @mention_regex
    |> Regex.scan(text, capture: :all)
    |> Enum.map(fn [placeholder, id] ->
      current? = id in bot_ids

      %{
        "kind" => if(current?, do: "bot", else: "user"),
        "structured" => true,
        "id" => id,
        "key" => placeholder,
        "user_id" => id,
        "name" => mention_name(namespace, id),
        "targets_current_agent" => current?,
        "agent_uid" => if(current?, do: consumer.context.agent_uid)
      }
      |> MapHelpers.compact_map()
    end)
  end

  defp mentions(_text, _consumer), do: []

  defp mention_name(namespace, id) do
    with {:ok, uid} <- Principals.resolve_platform_subject_uid(namespace, id),
         {:ok, principal} <- Principals.get_principal(uid),
         name when is_binary(name) <- principal.display_name do
      "@" <> name
    else
      _not_found -> "@" <> id
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
    |> String.replace(~r/<#([A-Z0-9]+)\|([^>]+)>/, "#\\2")
    |> String.replace(~r/<(https?:\/\/[^>|]+)\|([^>]+)>/, "\\2 (\\1)")
    |> String.replace(~r/<(https?:\/\/[^>]+)>/, "\\1")
    |> String.trim_leading()
    |> blank_to_nil()
  end

  defp strip_current_bot_mentions(text, mentions) do
    keys =
      mentions |> Enum.filter(&(&1["targets_current_agent"] == true)) |> Enum.map(& &1["key"])

    strip_prefixes(text, keys)
  end

  defp strip_prefixes(text, []), do: text

  defp strip_prefixes(text, keys) do
    trimmed = String.trim_leading(text)

    case Enum.find(keys, &String.starts_with?(trimmed, &1)) do
      nil -> trimmed
      key -> strip_prefixes(String.replace_prefix(trimmed, key, ""), keys)
    end
  end

  defp attachment_maps(message, source_entry_id) do
    attachments =
      message
      |> MapHelpers.fetch_list("files")
      |> Enum.flat_map(fn file ->
        if Map.get(file, "mode") == "tombstone" or not is_binary(Map.get(file, "url_private")) do
          []
        else
          [
            MapHelpers.compact_map(%{
              "provider_ref" => "slack:file:#{file["id"]}",
              "provider" => "slack",
              "source_message_id" => source_entry_id,
              "file_id" => file["id"],
              "name" => file["name"],
              "mimetype" => file["mimetype"],
              "size" => file["size"],
              "url_private" => file["url_private"]
            })
          ]
        end
      end)

    {:ok, attachments}
  end

  defp maybe_materialize_attachments(attachments, _message, %{materialize_attachments: false}),
    do: {:ok, attachments}

  defp maybe_materialize_attachments(
         attachments,
         message,
         %{attachment_materializer: fun} = consumer
       ),
       do: fun.(attachments, message, consumer)

  defp materialize_attachments(attachments, _message, %{config: config}) do
    client = Config.client(config)
    {:ok, Enum.map(attachments, &materialize_attachment(&1, client))}
  end

  defp materialize_attachment(attachment, client) do
    with {:ok, download} <- SlackOpenAPI.download(client, attachment["url_private"]),
         relative <- materialized_path(attachment, download.filename),
         {:ok, result} <- WorkerFiles.put("user_files", relative, download.body) do
      attachment
      |> Map.put("agent_computer_path", "/workspace/user-files/#{relative}")
      |> Map.put("user_files_relative_path", relative)
      |> MapHelpers.maybe_put("xxh3_128", result["xxh3_128"])
      |> MapHelpers.maybe_put("size", result["size"])
    else
      reason ->
        Logging.warning(
          "slack_adapter.attachment.materialization_skipped",
          "Slack attachment materialization skipped",
          %{provider_ref: attachment["provider_ref"], reason: inspect(reason)}
        )

        attachment
    end
  rescue
    exception ->
      Logging.warning(
        "slack_adapter.attachment.materialization_failed",
        "Slack attachment materialization failed",
        %{provider_ref: attachment["provider_ref"], error: Exception.message(exception)}
      )

      attachment
  end

  defp materialized_path(attachment, downloaded_name) do
    Path.join([
      "inbox",
      "slack",
      sanitize(attachment["source_message_id"]),
      sanitize(attachment["file_id"]),
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

  defp maybe_backfill_attachments(
         [],
         text,
         mentions,
         user_id,
         channel_id,
         provider_time,
         consumer
       ) do
    if is_binary(text) and not Enum.any?(mentions, &(&1["targets_current_agent"] == false)) and
         Regex.match?(~r/(上面|前面|文件|图片|附件|above|previous|file|image|attachment)/i, text) do
      SignalsGateway.recent_entry_attachments(
        signal_channel_id(channel_id),
        user_id,
        provider_time,
        window_seconds: consumer.recent_attachment_window_seconds,
        limit: consumer.max_backfilled_attachments
      )
    else
      []
    end
  end

  defp maybe_backfill_attachments(
         attachments,
         _text,
         _mentions,
         _user,
         _channel,
         _time,
         _consumer
       ),
       do: attachments

  defp provider_time(ts, event) do
    case Float.parse(ts) do
      {seconds, _rest} -> DateTime.from_unix!(round(seconds * 1_000_000), :microsecond)
      :error -> event.created_at
    end
  end

  defp channel_kind(message) do
    if Map.get(message, "channel_type") == "im", do: :im_dm, else: :im_group
  end

  @doc false
  def signal_channel_id(channel), do: "slack:" <> URI.encode(channel)

  defp provider_thread_id(channel, thread_ts),
    do: "slack:#{URI.encode(channel)}:#{URI.encode(thread_ts)}"

  # provider_thread_id names the thread that already contains the message, so
  # only threaded replies (and thread broadcasts) carry one. Falling back to the
  # message's own ts would give every top-level message its own inbound-batch
  # key, so same-sender bursts could never merge.
  defp message_thread_id(slack_channel_id, message) when is_map(message) do
    source_entry_id = MapHelpers.optional_text(message, "ts")

    case MapHelpers.optional_text(message, "thread_ts") do
      thread_ts when is_nil(thread_ts) or thread_ts == source_entry_id -> nil
      thread_ts -> provider_thread_id(slack_channel_id, thread_ts)
    end
  end

  defp reply_target_id(message, source_entry_id) do
    case MapHelpers.optional_text(message, "thread_ts") do
      thread_ts when is_nil(thread_ts) or thread_ts == source_entry_id -> nil
      thread_ts -> thread_ts
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
  defp ignored_status(:provider_self_sender), do: :ignored_provider_self_sender
  defp ignored_status(:empty_or_unsupported_message), do: :ignored_empty_or_unsupported_message
  defp ignored_status(reason), do: :"ignored_#{reason}"

  defp maybe_log_missing_sender(event, {:ok, results}) do
    if Enum.any?(results, &(Map.get(&1, :reason) == :missing_platform_subject)) do
      Logging.warning(
        "slack_adapter.inbound.missing_platform_subject",
        "Slack message ignored without user id",
        %{event_id: event.id, event_type: event.type}
      )
    end
  end

  defp maybe_log_missing_sender(_event, _result), do: :ok
end
