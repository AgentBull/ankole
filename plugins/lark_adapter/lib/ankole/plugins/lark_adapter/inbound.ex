defmodule Ankole.Plugins.LarkAdapter.Inbound do
  @moduledoc """
  Feishu/Lark inbound normalization into SignalsGateway adapter APIs.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ankole.ActorRuntime
  alias Ankole.JSON
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Emoji
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.SignalEntry
  alias FeishuOpenAPI.CardAction
  alias FeishuOpenAPI.Event

  @recent_attachment_window_seconds 120
  @max_backfilled_attachments 3

  @doc """
  Builds the dispatcher consumer record for one SignalsGateway chat binding.
  """
  @spec chat_consumer(AdapterContext.t(), map(), keyword()) :: map()
  def chat_consumer(%AdapterContext{} = context, config, opts \\ []) when is_map(config) do
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
        Keyword.get(opts, :attachment_materializer, &materialize_lark_attachments/3)
    }
  end

  @doc """
  Handles a provider message-create event for all chat consumers.
  """
  @spec handle_message_receive(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_message_receive(&1, event))
  end

  @doc """
  Handles a provider message-recall event for all chat consumers.
  """
  @spec handle_message_recalled(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_message_recalled(_event_type, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_message_recalled(&1, event))
  end

  @doc """
  Handles a provider reaction-add event for all chat consumers.
  """
  @spec handle_reaction_created(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_reaction_created(_event_type, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_reaction(&1, event, :add))
  end

  @doc """
  Handles a provider reaction-remove event for all chat consumers.
  """
  @spec handle_reaction_deleted(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_reaction_deleted(_event_type, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_reaction(&1, event, :remove))
  end

  @doc """
  Handles an interactive card action event for all chat consumers.
  """
  @spec handle_card_action(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, %Event{} = event, consumers) do
    action = CardAction.from_payload(event.content || event.raw)
    dispatch_chat(consumers, &emit_card_action(&1, action, event))
  end

  @doc """
  Normalizes a receive event without submitting it. This is the main test seam.
  """
  @spec normalize_message_receive(Event.t(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(
        %Event{} = event,
        %{context: %AdapterContext{}, config: config} = consumer
      ) do
    content = event.content || %{}
    message = fetch_map(content, "message", content)
    sender = fetch_map(content, "sender", %{})
    sender_ids = fetch_map(sender, "sender_id", sender)

    case ignored_sender?(sender, event) do
      true ->
        {:ignore, :provider_self_sender}

      false ->
        with {:ok, provider_entry_id} <- required_text(message, "message_id"),
             {:ok, chat_id} <- required_text(message, "chat_id"),
             {:ok, author} <- author(sender, sender_ids, event, consumer),
             {:ok, text} <- message_text(message),
             {:ok, attachments} <- attachments(message),
             :ok <- material_message?(text, attachments),
             {:ok, mentions} <- mentions(message),
             provider_time <- provider_time(message, event),
             channel_kind <- channel_kind(message),
             signal_channel_id <- signal_channel_id(chat_id),
             provider_thread_id <-
               provider_thread_id(chat_id, root_id(message, provider_entry_id)),
             attachments <-
               maybe_backfill_attachments(
                 attachments,
                 text,
                 mentions,
                 author,
                 signal_channel_id,
                 provider_time,
                 consumer
               ),
             {:ok, attachments} <- maybe_materialize_attachments(attachments, message, consumer) do
          {:ok,
           %{
             ingress_event_id: event.id || provider_entry_id,
             provider_entry_id: provider_entry_id,
             signal_channel_id: signal_channel_id,
             provider_thread_id: provider_thread_id,
             channel: %{
               kind: channel_kind,
               reply_mode: :entry,
               name: optional_text(message, "chat_name"),
               metadata: %{
                 "chat_id" => chat_id,
                 "chat_type" => optional_text(message, "chat_type"),
                 "domain" => Map.fetch!(config, "domain"),
                 "app_id" => event.app_id || Map.fetch!(config, "appId")
               },
               raw_payload: compact_map(message)
             },
             text: text,
             formatted_content: formatted_content(text),
             attachments: attachments,
             mentions: mentions,
             structured_mention_prefixes: mention_prefixes(mentions),
             explicit: explicit?(channel_kind, mentions),
             author: author,
             sender_key: author["principal_uid"] || author["id"],
             metadata: %{
               "provider" => "lark",
               "event_type" => event.type,
               "message_type" => optional_text(message, "message_type"),
               "tenant_key" => event.tenant_key
             },
             raw_payload: compact_map(event.raw),
             provider_time: provider_time
           }}
        end
    end
  end

  def normalize_message_receive(_event, _consumer), do: {:error, :invalid_chat_consumer}

  defp emit_message_receive(%{context: %AdapterContext{}} = consumer) do
    fn event ->
      case normalize_message_receive(event, consumer) do
        {:ok, input} ->
          with :ok <- observe_author(consumer, input) do
            AdapterContext.emit_entry(consumer.context, input)
          end

        {:ignore, reason} ->
          {:ok, %{status: ignored_status(reason), reason: reason}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp emit_message_receive(consumer, event), do: emit_message_receive(consumer).(event)

  defp emit_message_recalled(%{context: %AdapterContext{}} = consumer, %Event{} = event) do
    content = event.content || %{}
    message = fetch_map(content, "message", content)

    with {:ok, provider_entry_id} <- required_text(message, "message_id"),
         {:ok, chat_id} <- required_text(message, "chat_id") do
      input = %{
        ingress_event_id: event.id || "recall:#{provider_entry_id}",
        signal_channel_id: signal_channel_id(chat_id),
        provider_entry_id: provider_entry_id,
        provider_thread_id: provider_thread_id(chat_id, root_id(message, provider_entry_id)),
        channel: %{
          kind: channel_kind(message),
          reply_mode: :entry,
          raw_payload: compact_map(message)
        },
        metadata: %{"provider" => "lark", "event_type" => event.type},
        raw_payload: compact_map(event.raw),
        provider_time: provider_time(message, event)
      }

      AdapterContext.emit_entry_recalled(consumer.context, input)
    end
  end

  defp emit_reaction(%{context: %AdapterContext{}} = consumer, %Event{} = event, action) do
    content = event.content || %{}
    message = fetch_map(content, "message", content)
    operator = fetch_map(content, "operator", fetch_map(content, "operator_id", %{}))
    operator_id = optional_text(operator, "user_id") || optional_text(content, "operator_user_id")

    with {:ok, actor_key} <- operator_actor_key(operator_id),
         {:ok, provider_entry_id} <- required_text(message, "message_id"),
         {:ok, chat_id} <- required_text(message, "chat_id"),
         raw_reaction_key <- reaction_key(content) do
      input = %{
        ingress_event_id: event.id || "reaction:#{action}:#{provider_entry_id}:#{actor_key}",
        signal_channel_id: signal_channel_id(chat_id),
        provider_entry_id: provider_entry_id,
        reaction_key: Emoji.normalize(raw_reaction_key),
        raw_reaction_key: raw_reaction_key,
        actor_key: actor_key,
        action: action,
        raw_payload: compact_map(event.raw),
        provider_time: provider_time(message, event)
      }

      AdapterContext.emit_reaction(consumer.context, input)
    else
      {:error, :missing_operator_id} ->
        Logger.warning("lark adapter ignored reaction without operator user id")
        {:ok, %{status: :ignored_missing_operator}}

      {:error, _reason} = error ->
        error
    end
  end

  defp emit_card_action(
         %{context: %AdapterContext{}} = consumer,
         %CardAction{} = action,
         %Event{} = event
       ) do
    with {:ok, operator_id} <- operator_actor_key(action.user_id),
         {:ok, chat_id} <- required_text(action, "open_chat_id"),
         {:ok, action_id} <- card_action_id(action, event) do
      input = %{
        ingress_event_id: event.id || action_id,
        action_id: action_id,
        signal_channel_id: signal_channel_id(chat_id),
        provider_entry_id: action.open_message_id,
        provider_thread_id: provider_thread_id(chat_id, action.open_message_id || action_id),
        actor_input_type: "signal.action.invoked",
        action: %{
          "name" => action_name(action),
          "value" => action_value(action),
          "operator_id" => operator_id,
          "provider_entry_id" => action.open_message_id
        },
        raw_payload: compact_map(action.raw)
      }

      AdapterContext.emit_action(consumer.context, input)
    else
      {:error, :missing_operator_id} ->
        Logger.warning("lark adapter ignored card action without operator user id")
        {:ok, %{status: :ignored_missing_operator}}

      {:error, _reason} = error ->
        error
    end
  end

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> collect_results()
  end

  defp observe_author(%{context: context, config: config}, %{
         author: %{"platform_subject" => user_id} = author
       })
       when is_binary(user_id) do
    attrs = %{
      provider: Map.get(config, "platformSubjectNamespace", "lark-main"),
      external_id: user_id,
      uid: user_id,
      display_name: author["display_name"],
      metadata: Map.get(author, "metadata", %{})
    }

    # Chat traffic can reveal humans before a full contact sync runs. Observing
    # the platform subject here keeps future mentions and AuthZ checks convergent.
    case AdapterContext.observe_platform_subject(context, attrs) do
      {:ok, _observed} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp observe_author(_consumer, _input), do: :ok

  defp ignored_sender?(sender, event), do: sender_type(sender, event) in ["bot", "app"]

  defp sender_type(sender, event) do
    optional_text(sender, "sender_type") || optional_text(event.raw, "sender_type")
  end

  defp ignored_status(:provider_self_sender), do: :ignored_provider_self_sender
  defp ignored_status(:empty_or_unsupported_message), do: :ignored_empty_or_unsupported_message
  defp ignored_status(reason), do: :"ignored_#{reason}"

  defp author(sender, sender_ids, event, %{config: config}) do
    user_id = optional_text(sender_ids, "user_id")
    open_id = optional_text(sender_ids, "open_id")
    union_id = optional_text(sender_ids, "union_id")
    sender_type = sender_type(sender, event)
    display_name = optional_text(sender, "sender_name") || optional_text(sender, "name")

    cond do
      is_binary(user_id) ->
        {:ok,
         %{
           "id" => user_id,
           "platform_subject" => user_id,
           "principal_uid" => String.downcase(user_id),
           "display_name" => display_name,
           "metadata" =>
             compact_map(%{
               "open_id" => open_id,
               "union_id" => union_id,
               "tenant_key" => event.tenant_key,
               "sender_type" => sender_type,
               "provider" => Map.get(config, "platformSubjectNamespace", "lark-main")
             })
         }}

      true ->
        {:error, :missing_platform_subject}
    end
  end

  defp message_text(message) do
    message_type = optional_text(message, "message_type")
    content = decoded_content(message)

    text =
      case message_type do
        "text" -> optional_text(content, "text") || optional_text(message, "text")
        "post" -> post_text(content)
        _type -> nil
      end

    case text do
      value when is_binary(value) -> {:ok, value}
      nil -> {:ok, nil}
    end
  end

  defp material_message?(text, _attachments) when is_binary(text), do: :ok
  defp material_message?(nil, [_ | _]), do: :ok
  defp material_message?(_text, _attachments), do: {:ignore, :empty_or_unsupported_message}

  defp post_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> List.flatten()
    |> Enum.map(&post_part_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> blank_to_nil()
  end

  defp post_text(_content), do: nil

  defp post_part_text(%{"text" => text}) when is_binary(text), do: text
  defp post_part_text(%{"href" => href}) when is_binary(href), do: href
  defp post_part_text(_part), do: nil

  defp attachments(message) do
    message_type = optional_text(message, "message_type")
    content = decoded_content(message)

    attachments =
      case message_type do
        type when type in ["image", "file", "audio", "media", "video"] ->
          [resource_attachment(type, content, message)]

        _type ->
          []
      end
      |> Enum.reject(&is_nil/1)

    {:ok, attachments}
  end

  defp resource_attachment(type, content, message) do
    key =
      optional_text(content, "file_key") ||
        optional_text(content, "image_key") ||
        optional_text(content, "media_key")

    case key do
      value when is_binary(value) ->
        %{
          "provider_ref" => "lark:#{download_type(type)}:#{value}",
          "provider" => "lark",
          "source_message_id" => optional_text(message, "message_id"),
          "file_key" => value,
          "download_type" => download_type(type),
          "resource_type" => type,
          "name" => optional_text(content, "file_name"),
          "cover_image_key" => optional_text(content, "cover_image_key"),
          "duration" => fetch_value(content, "duration")
        }
        |> compact_map()

      nil ->
        nil
    end
  end

  defp download_type("image"), do: "image"
  defp download_type(_type), do: "file"

  defp mentions(message) do
    mentions =
      message
      |> fetch_list("mentions")
      |> Enum.map(&normalize_mention/1)

    {:ok, mentions}
  end

  defp normalize_mention(mention) when is_map(mention) do
    id = fetch_map(mention, "id", %{})

    %{
      "kind" => "bot",
      "structured" => true,
      "name" => optional_text(mention, "name"),
      "key" => optional_text(mention, "key"),
      "id" => optional_text(id, "user_id") || optional_text(id, "open_id"),
      "open_id" => optional_text(id, "open_id"),
      "user_id" => optional_text(id, "user_id")
    }
    |> compact_map()
  end

  defp normalize_mention(_mention), do: %{"kind" => "bot", "structured" => true}

  defp maybe_backfill_attachments(
         [_ | _] = attachments,
         _text,
         _mentions,
         _author,
         _channel,
         _time,
         _consumer
       ),
       do: attachments

  defp maybe_backfill_attachments(
         [],
         text,
         [_ | _],
         author,
         signal_channel_id,
         %DateTime{} = provider_time,
         consumer
       ) do
    case recent_attachment_intent?(text) do
      true -> recent_attachments(signal_channel_id, author, provider_time, consumer)
      false -> []
    end
  end

  defp maybe_backfill_attachments([], _text, _mentions, _author, _channel, _time, _consumer),
    do: []

  defp maybe_materialize_attachments(attachments, _message, %{materialize_attachments: false}),
    do: {:ok, attachments}

  defp maybe_materialize_attachments(
         attachments,
         message,
         %{
           materialize_attachments: true,
           attachment_materializer: materializer
         } = consumer
       )
       when is_function(materializer, 3) do
    materializer.(attachments, message, consumer)
  end

  defp materialize_lark_attachments(attachments, _message, %{config: config}) do
    client = Config.client(config)

    {:ok, Enum.map(attachments, &materialize_lark_attachment(&1, client))}
  end

  defp materialize_lark_attachment(%{} = attachment, client) do
    with source_message_id when is_binary(source_message_id) <- attachment["source_message_id"],
         file_key when is_binary(file_key) <- attachment["file_key"],
         download_type when is_binary(download_type) <- attachment["download_type"],
         {:ok, download} <-
           FeishuOpenAPI.download(client, "im/v1/messages/:message_id/resources/:file_key",
             path_params: %{message_id: source_message_id, file_key: file_key},
             query: [type: download_type]
           ),
         relative_path <- materialized_relative_path(source_message_id, attachment, download),
         {:ok, result} <- ActorRuntime.put_worker_file("user_files", relative_path, download.body) do
      attachment
      |> Map.put("agent_computer_path", "/workspace/user-files/#{relative_path}")
      |> Map.put("user_files_relative_path", relative_path)
      |> maybe_put("xxh3_128", result["xxh3_128"])
      |> maybe_put("size", result["size"])
    else
      reason ->
        Logger.warning(
          "lark attachment materialization skipped provider_ref=#{inspect(attachment["provider_ref"])} reason=#{inspect(reason)}"
        )

        attachment
    end
  rescue
    error ->
      Logger.warning(
        "lark attachment materialization failed provider_ref=#{inspect(attachment["provider_ref"])} error=#{Exception.message(error)}"
      )

      attachment
  end

  defp materialized_relative_path(source_message_id, attachment, download) do
    filename =
      download.filename ||
        attachment["name"] ||
        attachment["file_key"] ||
        "attachment"

    Path.join([
      "inbox",
      "lark",
      sanitize_path_segment(source_message_id),
      sanitize_path_segment(attachment["file_key"]),
      sanitize_path_segment(filename)
    ])
  end

  defp sanitize_path_segment(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unnamed"
      segment -> String.slice(segment, 0, 160)
    end
  end

  defp sanitize_path_segment(_value), do: "unnamed"

  defp recent_attachment_intent?(text) when is_binary(text) do
    Regex.match?(~r/(上面|前面|文件|图片|附件|above|previous|file|image|attachment)/i, text)
  end

  defp recent_attachment_intent?(_text), do: false

  defp recent_attachments(signal_channel_id, author, provider_time, consumer) do
    since =
      DateTime.add(
        provider_time,
        -Map.fetch!(consumer, :recent_attachment_window_seconds),
        :second
      )

    max = Map.fetch!(consumer, :max_backfilled_attachments)
    author_id = author["id"]

    SignalEntry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where([entry], entry.provider_time >= ^since and entry.provider_time <= ^provider_time)
    |> order_by([entry], desc: entry.provider_time)
    |> limit(20)
    |> Repo.all()
    |> Enum.filter(&(get_in(&1.author || %{}, ["id"]) == author_id))
    |> Enum.flat_map(&(&1.attachments || []))
    |> Enum.take(max)
  end

  defp formatted_content(nil), do: %{}
  defp formatted_content(text), do: %{"format" => "markdown", "body" => text}

  defp explicit?(:im_dm, _mentions), do: true
  defp explicit?(:im_group, [_ | _]), do: true
  defp explicit?(_kind, _mentions), do: false

  defp channel_kind(message) do
    case optional_text(message, "chat_type") do
      value when value in ["p2p", "private", "dm"] -> :im_dm
      _value -> :im_group
    end
  end

  defp root_id(message, provider_entry_id) do
    optional_text(message, "root_id") ||
      optional_text(message, "parent_id") ||
      provider_entry_id
  end

  defp signal_channel_id(chat_id), do: "lark:#{encode_id(chat_id)}"

  defp provider_thread_id(chat_id, root_id),
    do: "lark:#{encode_id(chat_id)}:#{encode_id(root_id)}"

  defp encode_id(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp provider_time(message, %Event{} = event) do
    parse_provider_time(
      fetch_value(message, "create_time") ||
        fetch_value(message, "update_time") ||
        fetch_value(message, "recall_time") ||
        event.created_at
    )
  end

  defp parse_provider_time(%DateTime{} = value), do: value

  defp parse_provider_time(value) when is_integer(value) do
    unit = if value > 10_000_000_000, do: :millisecond, else: :second
    DateTime.from_unix!(value, unit)
  end

  defp parse_provider_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> parse_provider_time(integer)
      _other -> nil
    end
  end

  defp parse_provider_time(_value), do: nil

  defp reaction_key(content) do
    reaction = fetch_map(content, "reaction", content)
    type = fetch_map(reaction, "reaction_type", reaction)

    optional_text(type, "emoji_type") ||
      optional_text(reaction, "emoji_type") ||
      optional_text(content, "emoji_type") ||
      "unknown"
  end

  defp operator_actor_key(value) when is_binary(value) and value != "", do: {:ok, value}
  defp operator_actor_key(_value), do: {:error, :missing_operator_id}

  defp card_action_id(%CardAction{} = action, %Event{} = event) do
    name = action_name(action)

    cond do
      is_binary(event.id) ->
        {:ok, event.id}

      is_binary(action.open_message_id) and is_binary(name) ->
        {:ok, "card:#{action.open_message_id}:#{name}"}

      true ->
        {:error, :missing_action_id}
    end
  end

  defp action_name(%CardAction{action: action}) when is_map(action) do
    optional_text(action, "name") || optional_text(action, "tag") || "card_action"
  end

  defp action_name(_action), do: "card_action"

  defp action_value(%CardAction{action: action}) when is_map(action) do
    fetch_value(action, "value") || action
  end

  defp action_value(_action), do: %{}

  defp mention_prefixes(mentions), do: Enum.flat_map(mentions, &mention_prefix_values/1)

  defp mention_prefix_values(mention) do
    key = optional_text(mention, "key")

    [key, at_prefixed_key(key), optional_text(mention, "name")]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp at_prefixed_key("@" <> _rest), do: nil
  defp at_prefixed_key(key) when is_binary(key), do: "@#{key}"
  defp at_prefixed_key(_key), do: nil

  defp decoded_content(message) do
    case fetch_value(message, "content") do
      content when is_map(content) ->
        content

      content when is_binary(content) ->
        case JSON.decode(content) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _error -> %{}
        end

      _content ->
        %{}
    end
  end

  defp required_text(%CardAction{} = action, key), do: required_text(Map.from_struct(action), key)

  defp required_text(map, key) do
    case optional_text(map, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:missing, key}}
    end
  end

  defp optional_text(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp fetch_map(map, key, default) when is_map(map) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp fetch_list(map, key) when is_map(map) do
    case fetch_value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    atom_key = atom_key(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)
      true -> nil
    end
  end

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp atom_key(_key), do: nil

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
