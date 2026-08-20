defmodule Ankole.Plugins.LarkAdapter.Inbound do
  @moduledoc """
  Feishu/Lark inbound normalization into SignalsGateway adapter APIs.
  """

  alias Ankole.JSON
  alias Ankole.Logging
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Emoji
  alias Ankole.Plugins.LarkAdapter.IMGroups
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.WorkerFiles
  alias FeishuOpenAPI.CardAction
  alias FeishuOpenAPI.Event

  import MapHelpers,
    only: [
      collect_results: 1,
      compact_map: 1,
      fetch_list: 2,
      fetch_map: 3,
      fetch_value: 2,
      maybe_put: 3,
      optional_text: 2
    ]

  @recent_attachment_window_seconds 120
  @max_backfilled_attachments 3
  @post_locale_priority ~w(zh_cn en_us ja_jp)
  @markdown_inline_token ~r/(`+)|!\[[^\]]*\]\(\s*(img_[A-Za-z0-9_-]+)(?:\s+["'][^"']*["'])?\s*\)/u
  @attachment_id_min 10_000
  @attachment_id_max 9_007_199_254_740_991

  @doc """
  Builds the dispatcher consumer record for one SignalsGateway chat binding.
  """
  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{
      kind: :chat,
      context: context,
      config: config,
      recent_attachment_window_seconds: @recent_attachment_window_seconds,
      max_backfilled_attachments: @max_backfilled_attachments
    }
  end

  @doc """
  Handles a provider message-create event for all chat consumers.
  """
  @spec handle_message_receive(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, %Event{} = event, consumers) do
    observed_at = DateTime.utc_now(:microsecond)

    result =
      consumers
      |> Enum.filter(&match?(%{kind: :chat}, &1))
      |> Enum.map(&prepare_message_receive(&1, event, observed_at))
      |> collect_results()
      |> emit_prepared_messages()

    maybe_log_missing_platform_subject(event, result)
    result
  end

  @doc """
  Handles a provider message-removal event for all chat consumers.
  """
  @spec handle_message_removed(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_message_removed(_event_type, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_message_removed(&1, event))
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
        %{context: %AdapterContext{}} = consumer
      ) do
    with {:ok, input, _message} <- normalize_message_receive_input(event, consumer) do
      {:ok, input}
    end
  end

  def normalize_message_receive(_event, _consumer), do: {:error, :invalid_chat_consumer}

  defp normalize_message_receive_input(
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
        with {:ok, source_entry_id} <- required_text(message, "message_id"),
             {:ok, chat_id} <- required_text(message, "chat_id"),
             {:ok, author} <- author(sender, sender_ids, event, consumer),
             {:ok, raw_text} <- message_text(message),
             {:ok, attachments} <- attachments(message),
             {:ok, mentions} <- mentions(message, consumer),
             text <- visible_message_text(raw_text, mentions),
             :ok <- material_message?(raw_text, attachments),
             provider_time <- provider_time(message, event),
             channel_kind <- channel_kind(message),
             signal_channel_id <- signal_channel_id(chat_id),
             provider_thread_id <- message_thread_id(chat_id, message),
             reply_to_source_entry_id <- reply_target_id(message, source_entry_id),
             attachments <-
               maybe_backfill_attachments(
                 attachments,
                 text,
                 mentions,
                 author,
                 signal_channel_id,
                 provider_time,
                 consumer
               ) do
          {:ok,
           %{
             source_event_id: event.id || source_entry_id,
             source_entry_id: source_entry_id,
             signal_channel_id: signal_channel_id,
             reply_to_source_entry_id: reply_to_source_entry_id,
             provider_thread_id: provider_thread_id,
             channel: %{
               kind: channel_kind,
               reply_mode: :entry,
               name: optional_text(message, "chat_name"),
               metadata:
                 %{
                   "chat_id" => chat_id,
                   "chat_type" => optional_text(message, "chat_type"),
                   "domain" => Map.fetch!(config, "domain"),
                   "app_id" => event.app_id || Map.fetch!(config, "appID"),
                   "peer_open_id" =>
                     if(channel_kind == :im_dm,
                       do: get_in(author, ["metadata", "open_id"])
                     )
                 }
                 |> compact_map(),
               raw_payload: compact_map(message)
             },
             text: text,
             formatted_content: formatted_content(text),
             attachments: attachments,
             mentions: mentions,
             structured_mention_prefixes: mention_prefixes(mentions),
             explicit: explicit?(channel_kind, mentions, consumer),
             author: author,
             metadata: %{
               "provider" => "lark",
               "event_type" => event.type,
               "message_type" => optional_text(message, "message_type"),
               "tenant_key" => event.tenant_key
             },
             raw_payload: compact_map(event.raw),
             provider_time: provider_time
           }, message}
        end
    end
  end

  defp prepare_message_receive(
         %{context: %AdapterContext{}} = consumer,
         %Event{} = event,
         observed_at
       ) do
    case normalize_message_receive_input(event, consumer) do
      {:ok, input, message} ->
        {:ok,
         %{
           consumer: consumer,
           input: input,
           message: message,
           observed_at: observed_at
         }}

      {:ignore, reason} ->
        {:ok, %{result: {:ok, %{status: ignored_status(reason), reason: reason}}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp emit_prepared_messages({:ok, prepared}) do
    with {:ok, prepared} <- emit_pending_attachments(prepared) do
      prepared
      |> Enum.map(&emit_prepared_message/1)
      |> collect_results()
    end
  end

  defp emit_prepared_messages({:error, _reason} = error), do: error

  defp emit_pending_attachments(prepared) do
    prepared
    |> Enum.reduce_while({:ok, []}, fn
      %{consumer: consumer, input: input, observed_at: observed_at} = item, {:ok, items} ->
        if attachment_materialization_required?(input.attachments, consumer) do
          input
          |> put_attachment_materialization("pending", observed_at)
          |> emit_normalized_message(consumer, false)
          |> case do
            {:ok, result} ->
              attachments =
                case result do
                  %{signal_entry: %{attachments: attachments}} when is_list(attachments) ->
                    attachments

                  _other ->
                    nil
                end

              prepared_item =
                if attachments,
                  do: put_in(item, [:input, :attachments], attachments),
                  else: %{result: {:ok, result}}

              {:cont, {:ok, [prepared_item | items]}}

            {:error, _reason} = error ->
              {:halt, error}
          end
        else
          {:cont, {:ok, [item | items]}}
        end

      %{result: _result} = item, {:ok, items} ->
        {:cont, {:ok, [item | items]}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp emit_prepared_message(%{result: result}), do: result

  defp emit_prepared_message(%{
         consumer: consumer,
         input: input,
         message: message,
         observed_at: observed_at
       }) do
    with {:ok, attachments} <-
           maybe_materialize_attachments(input.attachments, message, consumer) do
      input
      |> Map.put(:attachments, attachments)
      |> put_attachment_materialization(materialization_result(attachments), observed_at)
      |> emit_normalized_message(consumer, true)
    end
  end

  defp emit_normalized_message(input, consumer, refresh_group?) do
    context = consumer.context
    result = Ingress.emit_entry(context.agent_uid, context.binding_name, input)

    if refresh_group? and match?({:ok, _}, result) do
      IMGroups.maybe_enqueue_missing_channel_refresh(consumer, input)
    end

    result
  end

  defp emit_message_removed(%{context: %AdapterContext{}} = consumer, %Event{} = event) do
    content = event.content || %{}
    message = fetch_map(content, "message", content)

    with {:ok, source_entry_id} <- required_text(message, "message_id"),
         {:ok, chat_id} <- required_text(message, "chat_id") do
      input = %{
        source_event_id: event.id || "recall:#{source_entry_id}",
        signal_channel_id: signal_channel_id(chat_id),
        source_entry_id: source_entry_id,
        provider_thread_id: message_thread_id(chat_id, message),
        channel: %{
          kind: removed_message_channel_kind(message),
          reply_mode: :entry,
          raw_payload: compact_map(message)
        },
        metadata: %{"provider" => "lark", "event_type" => event.type},
        raw_payload: compact_map(event.raw),
        provider_time: provider_time(message, event)
      }

      context = consumer.context

      Ingress.emit_entry_removed(context.agent_uid, context.binding_name, input,
        provider_lifecycle_kind: :recalled
      )
    end
  end

  defp emit_reaction(%{context: %AdapterContext{}} = consumer, %Event{} = event, action) do
    content = event.content || %{}
    message = fetch_map(content, "message", content)
    operator = fetch_map(content, "operator", fetch_map(content, "operator_id", %{}))

    operator_id =
      optional_text(operator, "user_id") ||
        optional_text(content, "operator_user_id") ||
        optional_text(operator, "open_id") ||
        optional_text(content, "operator_open_id")

    with {:ok, actor_key} <- operator_actor_key(operator_id),
         {:ok, source_entry_id} <- required_text(message, "message_id"),
         {:ok, chat_id} <- required_text(message, "chat_id"),
         raw_reaction_key <- reaction_key(content) do
      input = %{
        source_event_id: event.id || "reaction:#{action}:#{source_entry_id}:#{actor_key}",
        signal_channel_id: signal_channel_id(chat_id),
        source_entry_id: source_entry_id,
        reaction_key: Emoji.normalize(raw_reaction_key),
        raw_reaction_key: raw_reaction_key,
        actor_key: actor_key,
        action: action,
        raw_payload: compact_map(event.raw),
        provider_time: provider_time(message, event)
      }

      context = consumer.context
      Ingress.emit_reaction(context.agent_uid, context.binding_name, input)
    else
      {:error, :missing_operator_id} ->
        Logging.warning(
          "lark_adapter.inbound.reaction_missing_operator",
          "lark adapter ignored reaction without operator id",
          %{
            event_id: event.id,
            event_type: event.type
          }
        )

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
    with {:ok, operator_id} <- operator_actor_key(action.user_id || action.open_id),
         {:ok, operator_principal_uid} <- observe_card_operator(consumer, operator_id),
         {:ok, chat_id} <- required_text_value(action.open_chat_id, "open_chat_id"),
         {:ok, action_id} <- card_action_id(action, event) do
      input = %{
        source_event_id: event.id || action_id,
        action_id: action_id,
        signal_channel_id: signal_channel_id(chat_id),
        source_entry_id: action.open_message_id,
        provider_thread_id: provider_thread_id(chat_id, action.open_message_id || action_id),
        actor_event_type: "signal.action.invoked",
        action: %{
          "name" => action_name(action),
          "value" => action_value(action),
          "operator_id" => operator_id,
          "operator_principal_uid" => operator_principal_uid,
          "source_entry_id" => action.open_message_id
        },
        raw_payload: compact_map(action.raw)
      }

      context = consumer.context
      Ingress.emit_action(context.agent_uid, context.binding_name, input)
    else
      {:error, :missing_operator_id} ->
        Logging.warning(
          "lark_adapter.inbound.card_action_missing_operator",
          "lark adapter ignored card action without operator user id",
          %{
            event_id: event.id,
            event_type: event.type,
            action_id: action.open_message_id
          }
        )

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

  defp ignored_sender?(sender, event), do: sender_type(sender, event) in ["bot", "app"]

  defp sender_type(sender, event) do
    optional_text(sender, "sender_type") || optional_text(event.raw, "sender_type")
  end

  defp ignored_status(:provider_self_sender), do: :ignored_provider_self_sender
  defp ignored_status(:empty_or_unsupported_message), do: :ignored_empty_or_unsupported_message
  defp ignored_status(reason), do: :"ignored_#{reason}"

  # Sender ids by stability: user_id is the tenant-stable employee id, union_id
  # is stable across the tenant's own apps, open_id is app-local. External
  # tenant members carry no user_id, so the strongest available id becomes the
  # platform subject and the rest ride along as match candidates.
  defp author(sender, sender_ids, event, %{config: config}) do
    user_id = optional_text(sender_ids, "user_id")
    open_id = optional_text(sender_ids, "open_id")
    union_id = optional_text(sender_ids, "union_id")
    sender_type = sender_type(sender, event)
    display_name = optional_text(sender, "sender_name") || optional_text(sender, "name")

    case Enum.reject([user_id, union_id, open_id], &is_nil/1) do
      [] ->
        {:ignore, :missing_platform_subject}

      [primary | alternates] ->
        {:ok,
         %{
           "id" => primary,
           "platform_subject" => primary,
           "platform_subject_alternates" => alternates,
           "display_name" => display_name,
           "metadata" =>
             compact_map(%{
               "user_id" => user_id,
               "open_id" => open_id,
               "union_id" => union_id,
               "tenant_key" => event.tenant_key,
               "sender_type" => sender_type,
               "provider" => Map.get(config, "platformSubjectNamespace", "lark-main")
             })
         }}
    end
  end

  defp maybe_log_missing_platform_subject(%Event{} = event, {:ok, results}) do
    if Enum.any?(results, &(Map.get(&1, :reason) == :missing_platform_subject)) do
      content = event.content || %{}
      message = fetch_map(content, "message", content)
      sender = fetch_map(content, "sender", %{})
      sender_ids = fetch_map(sender, "sender_id", sender)

      Logging.warning(
        "lark_adapter.inbound.missing_platform_subject",
        "lark adapter ignored message sender without any sender id",
        %{
          event_id: event.id,
          event_type: event.type,
          chat_id: optional_text(message, "chat_id"),
          message_id: optional_text(message, "message_id"),
          sender_type: sender_type(sender, event),
          open_id: optional_text(sender_ids, "open_id"),
          union_id: optional_text(sender_ids, "union_id"),
          tenant_key: event.tenant_key
        }
      )
    end

    :ok
  end

  defp maybe_log_missing_platform_subject(_event, _result), do: :ok

  defp message_text(message) do
    message_type = optional_text(message, "message_type")
    content = decoded_content(message)

    text =
      case message_type do
        "text" -> optional_text(content, "text") || optional_text(message, "text")
        "post" -> post_text(content)
        "sticker" -> "<|sticker|>"
        "location" -> location_text(content)
        "share_chat" -> share_chat_text(content)
        "share_user" -> share_user_text(content)
        _type -> nil
      end

    case text do
      value when is_binary(value) -> {:ok, value}
      nil -> {:ok, nil}
    end
  end

  defp visible_message_text(nil, _mentions), do: nil

  defp visible_message_text(text, mentions) when is_binary(text) do
    text
    |> strip_leading_current_bot_mentions(mentions)
    |> render_structured_mentions(mentions)
    |> String.trim_leading()
    |> blank_to_nil()
  end

  defp strip_leading_current_bot_mentions(text, mentions) do
    prefixes =
      mentions
      |> Enum.filter(&current_bot_mention?/1)
      |> mention_prefixes()

    strip_leading_prefixes(text, prefixes)
  end

  defp strip_leading_prefixes(text, []), do: text

  defp strip_leading_prefixes(text, prefixes) do
    stripped = String.trim_leading(text)

    case Enum.find(prefixes, &String.starts_with?(stripped, &1)) do
      nil ->
        stripped

      prefix ->
        stripped
        |> String.replace_prefix(prefix, "")
        |> String.trim_leading()
        |> strip_leading_mention_separators()
        |> strip_leading_prefixes(prefixes)
    end
  end

  defp strip_leading_mention_separators(text) do
    case String.next_grapheme(text) do
      {separator, rest} when separator in [":", "：", ",", "，"] ->
        rest
        |> String.trim_leading()
        |> strip_leading_mention_separators()

      _no_separator ->
        text
    end
  end

  defp render_structured_mentions(text, mentions) do
    Enum.reduce(mentions, text, fn mention, acc ->
      case mention_visible_name(mention) do
        nil -> acc
        name -> replace_mention_placeholders(acc, mention, name)
      end
    end)
  end

  defp replace_mention_placeholders(text, mention, name) do
    mention
    |> mention_placeholder_values()
    |> Enum.reduce(text, fn placeholder, acc ->
      String.replace(acc, placeholder, name)
    end)
  end

  defp current_bot_mention?(mention) when is_map(mention),
    do: present_text?(Map.get(mention, "agent_uid"))

  defp current_bot_mention?(_mention), do: false

  defp mention_visible_name(mention) when is_map(mention), do: optional_text(mention, "name")
  defp mention_visible_name(_mention), do: nil

  defp material_message?(text, _attachments) when is_binary(text), do: :ok
  defp material_message?(nil, [_ | _]), do: :ok
  defp material_message?(_text, _attachments), do: {:ignore, :empty_or_unsupported_message}

  defp post_text(content) do
    content
    |> post_blocks()
    |> List.flatten()
    |> Enum.map(&post_part_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> blank_to_nil()
  end

  defp post_blocks(content) when is_map(content) do
    content = unwrap_localized_post(content)

    case Map.get(content, "content_v2") do
      blocks when is_list(blocks) and blocks != [] -> blocks
      _empty_or_malformed -> legacy_post_blocks(content)
    end
  end

  defp post_blocks(_content), do: []

  defp legacy_post_blocks(%{"content" => blocks}) when is_list(blocks), do: blocks
  defp legacy_post_blocks(_content), do: []

  defp unwrap_localized_post(content) do
    cond do
      Map.has_key?(content, "content") or Map.has_key?(content, "content_v2") ->
        content

      true ->
        preferred_localized_post(content) || fallback_localized_post(content) || content
    end
  end

  defp preferred_localized_post(content) do
    Enum.find_value(@post_locale_priority, fn locale ->
      case Map.get(content, locale) do
        localized when is_map(localized) -> if post_body?(localized), do: localized
        _missing_or_malformed -> nil
      end
    end)
  end

  defp fallback_localized_post(content) do
    content
    |> Enum.sort_by(fn {locale, _localized} -> locale end)
    |> Enum.find_value(fn
      {_locale, localized} when is_map(localized) -> if post_body?(localized), do: localized
      _malformed -> nil
    end)
  end

  defp post_body?(%{"content_v2" => blocks}) when is_list(blocks) and blocks != [], do: true
  defp post_body?(%{"content" => blocks}) when is_list(blocks) and blocks != [], do: true
  defp post_body?(_content), do: false

  defp post_part_text(%{"text" => text}) when is_binary(text), do: text
  defp post_part_text(%{"href" => href}) when is_binary(href), do: href
  defp post_part_text(%{"tag" => "img"}), do: "[image]"
  defp post_part_text(%{"tag" => "media"}), do: "[video]"

  defp post_part_text(%{"tag" => "emotion", "emoji_type" => emoji}) when is_binary(emoji),
    do: "[#{emoji}]"

  defp post_part_text(%{"tag" => "emotion", "emoji_key" => emoji}) when is_binary(emoji),
    do: "[#{emoji}]"

  defp post_part_text(_part), do: nil

  defp location_text(content) do
    fields =
      [
        tagged_text("name", optional_text(content, "name") || optional_text(content, "title")),
        tagged_text("address", optional_text(content, "address")),
        tagged_text("latitude", fetch_value(content, "latitude") || fetch_value(content, "lat")),
        tagged_text("longitude", fetch_value(content, "longitude") || fetch_value(content, "lng"))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> "<|location|>"
      fields -> "<|location|> #{Enum.join(fields, " ")}"
    end
  end

  defp share_chat_text(content) do
    fields =
      [
        tagged_text("chat_id", optional_text(content, "chat_id")),
        tagged_text("title", optional_text(content, "title") || optional_text(content, "name"))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> "<|share_chat|>"
      fields -> "<|share_chat|> #{Enum.join(fields, " ")}"
    end
  end

  defp share_user_text(content) do
    fields =
      [
        tagged_text(
          "user_id",
          optional_text(content, "user_id") || optional_text(content, "open_id")
        ),
        tagged_text("name", optional_text(content, "name"))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> "<|share_user|>"
      fields -> "<|share_user|> #{Enum.join(fields, " ")}"
    end
  end

  defp tagged_text(_key, nil), do: nil
  defp tagged_text(key, value) when is_binary(value) and value != "", do: "#{key}=#{value}"
  defp tagged_text(key, value) when is_number(value), do: "#{key}=#{value}"
  defp tagged_text(_key, _value), do: nil

  defp attachments(message) do
    message_type = optional_text(message, "message_type")
    content = decoded_content(message)

    attachments =
      case message_type do
        type when type in ["image", "file", "audio", "media", "video"] ->
          [resource_attachment(type, content, message)]

        "post" ->
          post_resource_attachments(content, message)

        _type ->
          []
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["provider_ref"])

    {:ok, attachments}
  end

  defp post_resource_attachments(content, message) do
    content
    |> post_blocks()
    |> List.flatten()
    |> Enum.flat_map(&post_part_attachments(&1, message))
  end

  defp post_part_attachments(%{"tag" => "img", "image_key" => image_key}, message)
       when is_binary(image_key) do
    [resource_attachment("image", %{"image_key" => image_key}, message)]
  end

  defp post_part_attachments(%{"tag" => "media"} = part, message) do
    case resource_attachment("media", part, message) do
      nil -> []
      attachment -> [attachment]
    end
  end

  defp post_part_attachments(%{"tag" => "md", "text" => markdown}, message)
       when is_binary(markdown) do
    markdown
    |> markdown_provider_image_keys()
    |> Enum.map(&resource_attachment("image", %{"image_key" => &1}, message))
  end

  defp post_part_attachments(_part, _message), do: []

  defp markdown_provider_image_keys(markdown) do
    markdown
    |> markdown_visible_blocks()
    |> Enum.reduce([], &markdown_block_provider_image_keys/2)
    |> Enum.reverse()
  end

  defp markdown_visible_blocks(markdown) do
    {open_fence, current, blocks} =
      markdown
      |> String.split("\n", trim: false)
      |> Enum.reduce({nil, [], []}, fn line, {open_fence, current, blocks} ->
        cond do
          open_fence != nil and closes_markdown_fence?(line, open_fence) ->
            {nil, [], blocks}

          open_fence != nil ->
            {open_fence, current, blocks}

          fence = markdown_fence_marker(line) ->
            {fence, [], put_markdown_block(current, blocks)}

          true ->
            {nil, [line | current], blocks}
        end
      end)

    blocks = if is_nil(open_fence), do: put_markdown_block(current, blocks), else: blocks
    Enum.reverse(blocks)
  end

  defp put_markdown_block([], blocks), do: blocks

  defp put_markdown_block(lines, blocks) do
    [lines |> Enum.reverse() |> Enum.join("\n") | blocks]
  end

  defp markdown_block_provider_image_keys(markdown, keys) do
    tokens = Regex.scan(@markdown_inline_token, markdown, return: :index)

    remaining_ticks =
      Enum.reduce(tokens, %{}, fn
        [_token, {_offset, tick_length}], counts when tick_length > 0 ->
          Map.update(counts, tick_length, 1, &(&1 + 1))

        _token, counts ->
          counts
      end)

    {_open_ticks, _remaining_ticks, keys} =
      Enum.reduce(tokens, {nil, remaining_ticks, keys}, fn
        [_token, {_offset, tick_length}], {open_ticks, remaining, keys}
        when tick_length > 0 ->
          remaining = Map.update!(remaining, tick_length, &(&1 - 1))

          cond do
            open_ticks == tick_length -> {nil, remaining, keys}
            not is_nil(open_ticks) -> {open_ticks, remaining, keys}
            Map.fetch!(remaining, tick_length) > 0 -> {tick_length, remaining, keys}
            true -> {nil, remaining, keys}
          end

        [_token, _ticks, {key_offset, key_length}], {nil, remaining, keys}
        when key_length > 0 ->
          {nil, remaining, [binary_part(markdown, key_offset, key_length) | keys]}

        _token, state ->
          state
      end)

    keys
  end

  defp markdown_fence_marker(line) do
    case Regex.run(~r/^\s*(`{3,}|~{3,})/, line, capture: :all_but_first) do
      [marker] -> marker
      nil -> nil
    end
  end

  defp closes_markdown_fence?(line, marker) do
    stripped = String.trim(line)
    marker_character = String.first(marker)

    String.length(stripped) >= String.length(marker) and
      stripped == String.duplicate(marker_character, String.length(stripped))
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

  defp mentions(message, consumer) do
    mentions =
      message
      |> fetch_list("mentions")
      |> Enum.map(&normalize_mention(&1, consumer))

    {:ok, mentions}
  end

  defp normalize_mention(mention, consumer) when is_map(mention) do
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
    |> mark_local_bot_mention(consumer)
    |> compact_map()
  end

  defp normalize_mention(_mention, consumer) do
    %{"kind" => "bot", "structured" => true}
    |> mark_local_bot_mention(consumer)
    |> compact_map()
  end

  # Lark events can contain mentions for another bot in the same group. A group
  # mention only addresses this binding when it matches the bot open_id resolved
  # for the live connection. A failed identity lookup must fail closed so
  # multiple agents in the same group do not all claim the same @bot.
  defp mark_local_bot_mention(mention, %{config: config, context: %AdapterContext{} = context}) do
    cond do
      not runtime_bot_identity_resolved?(config) ->
        Map.put(mention, "targets_current_agent", false)

      mention_targets_runtime_bot?(mention, config) ->
        Map.put(mention, "agent_uid", context.agent_uid)

      true ->
        Map.put(mention, "targets_current_agent", false)
    end
  end

  defp mark_local_bot_mention(mention, _consumer), do: mention

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

  defp maybe_materialize_attachments(attachments, message, consumer) do
    case Enum.all?(attachments, &materialized_attachment?(&1, consumer)) do
      true -> {:ok, attachments}
      false -> materialize_lark_attachments(attachments, message, consumer)
    end
  end

  defp attachment_materialization_required?([_ | _] = attachments, consumer),
    do: not Enum.all?(attachments, &materialized_attachment?(&1, consumer))

  defp attachment_materialization_required?(_attachments, _consumer), do: false

  defp materialization_result([_ | _] = attachments) do
    if Enum.all?(attachments, &materialized_attachment?/1), do: "complete", else: "failed"
  end

  defp materialization_result(_attachments), do: nil

  defp put_attachment_materialization(input, nil, _observed_at), do: input

  defp put_attachment_materialization(input, state, %DateTime{} = observed_at) do
    metadata =
      Map.put(input.metadata, "attachment_materialization", %{
        "state" => state,
        "observed_at" => DateTime.to_iso8601(observed_at)
      })

    Map.put(input, :metadata, metadata)
  end

  defp materialized_attachment?(attachment) when is_map(attachment) do
    with attachment_id when is_integer(attachment_id) <- valid_attachment_id(attachment),
         path when is_binary(path) <- attachment["agent_computer_path"] do
      String.contains?(path, "/user-files/inbox/#{attachment_id}/")
    else
      _missing_or_invalid -> false
    end
  end

  defp materialized_attachment?(_attachment), do: false

  defp materialized_attachment?(attachment, %{context: %{agent_uid: agent_uid}})
       when is_map(attachment) do
    with attachment_id when is_integer(attachment_id) <- valid_attachment_id(attachment),
         path when is_binary(path) <- attachment["agent_computer_path"] do
      String.starts_with?(
        path,
        Path.join([
          Ankole.AgentHomePaths.user_files(agent_uid),
          "inbox",
          Integer.to_string(attachment_id)
        ]) <> "/"
      )
    else
      _missing_or_invalid -> false
    end
  end

  defp materialized_attachment?(_attachment, _consumer), do: false

  defp materialize_lark_attachments(attachments, _message, %{
         config: config,
         context: %{agent_uid: agent_uid}
       }) do
    client = Config.client(config)

    {:ok, Enum.map(attachments, &materialize_lark_attachment(&1, client, agent_uid))}
  end

  defp materialize_lark_attachment(%{} = attachment, client, agent_uid) do
    with attachment_id when is_integer(attachment_id) <- valid_attachment_id(attachment),
         source_message_id when is_binary(source_message_id) <- attachment["source_message_id"],
         file_key when is_binary(file_key) <- attachment["file_key"],
         download_type when is_binary(download_type) <- attachment["download_type"],
         {:ok, download} <-
           FeishuOpenAPI.download(client, "im/v1/messages/:message_id/resources/:file_key",
             path_params: %{message_id: source_message_id, file_key: file_key},
             query: [type: download_type]
           ),
         relative_path <- materialized_relative_path(attachment_id, attachment, download),
         lane_path <- Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative_path),
         {:ok, result} <- WorkerFiles.put("user_files", lane_path, download.body) do
      attachment
      |> Map.put(
        "agent_computer_path",
        Path.join(Ankole.AgentHomePaths.user_files(agent_uid), relative_path)
      )
      |> Map.put("user_files_relative_path", relative_path)
      |> maybe_put("xxh3_128", result["xxh3_128"])
      |> maybe_put("size", result["size"])
    else
      reason ->
        Logging.warning(
          "lark_adapter.attachment.materialization_skipped",
          "lark attachment materialization skipped",
          %{
            provider_ref: attachment["provider_ref"],
            source_message_id: attachment["source_message_id"],
            file_key: attachment["file_key"],
            reason: inspect(reason)
          }
        )

        attachment
    end
  rescue
    error ->
      Logging.warning(
        "lark_adapter.attachment.materialization_failed",
        "lark attachment materialization failed",
        %{
          provider_ref: attachment["provider_ref"],
          error: Exception.message(error)
        }
      )

      attachment
  end

  defp materialized_relative_path(attachment_id, attachment, download) do
    filename =
      download.filename ||
        attachment["name"] ||
        "attachment"

    Path.join([
      "inbox",
      Integer.to_string(attachment_id),
      sanitize_filename(filename)
    ])
  end

  defp sanitize_filename(value) when is_binary(value) do
    value
    |> Ankole.Kernel.any_ascii()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 160)
    |> case do
      segment when segment in ["", ".", ".."] -> "attachment"
      segment -> segment
    end
  end

  defp sanitize_filename(_value), do: "attachment"

  defp valid_attachment_id(%{"attachment_id" => attachment_id})
       when is_integer(attachment_id) and attachment_id >= @attachment_id_min and
              attachment_id <= @attachment_id_max,
       do: attachment_id

  defp valid_attachment_id(_attachment), do: nil

  defp recent_attachment_intent?(text) when is_binary(text) do
    # Lark sends attachment-only messages separately from the later textual
    # mention ("use the file above"). Keep this heuristic local to the adapter
    # because it depends on provider-language UX, while the actual mirror query
    # stays behind SignalsGateway.recent_entry_attachments/4.
    Regex.match?(~r/(上面|前面|文件|图片|附件|above|previous|file|image|attachment)/i, text)
  end

  defp recent_attachment_intent?(_text), do: false

  defp recent_attachments(signal_channel_id, author, provider_time, consumer) do
    max = Map.fetch!(consumer, :max_backfilled_attachments)
    author_id = author["id"]

    SignalsGateway.recent_entry_attachments(signal_channel_id, author_id, provider_time,
      window_seconds: Map.fetch!(consumer, :recent_attachment_window_seconds),
      limit: max
    )
  end

  defp formatted_content(nil), do: %{}
  defp formatted_content(text), do: %{"format" => "markdown", "body" => text}

  defp explicit?(:im_dm, _mentions, _consumer), do: true

  defp explicit?(:im_group, mentions, consumer),
    do: Enum.any?(mentions, &mention_targets_current_binding?(&1, consumer))

  defp mention_targets_current_binding?(mention, %{
         context: %AdapterContext{} = context
       })
       when is_map(mention) do
    case optional_text(mention, "agent_uid") do
      nil -> false
      agent_uid -> agent_uid == context.agent_uid
    end
  end

  defp mention_targets_current_binding?(_mention, _consumer), do: false

  defp runtime_bot_identity_resolved?(config) when is_map(config),
    do: present_text?(Map.get(config, "runtimeBotOpenID"))

  defp runtime_bot_identity_resolved?(_config), do: false

  defp mention_targets_runtime_bot?(mention, config) when is_map(mention) and is_map(config) do
    bot_open_id = Map.get(config, "runtimeBotOpenID")

    matches_optional_id?(mention["open_id"], bot_open_id) or
      matches_optional_id?(mention["id"], bot_open_id)
  end

  defp mention_targets_runtime_bot?(_mention, _config), do: false

  defp matches_optional_id?(value, expected) when is_binary(value) and is_binary(expected),
    do: String.trim(value) != "" and value == expected

  defp matches_optional_id?(_value, _expected), do: false

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp channel_kind(message) do
    case optional_text(message, "chat_type") do
      value when value in ["p2p", "private", "dm"] -> :im_dm
      _value -> :im_group
    end
  end

  defp removed_message_channel_kind(message) do
    case optional_text(message, "chat_type") do
      value when value in ["p2p", "private", "dm"] -> :im_dm
      "group" -> :im_group
      _value -> :unknown
    end
  end

  # provider_thread_id names the thread that already contains the message, so
  # only provider-marked replies carry one. A self-id fallback would give every
  # top-level message its own inbound-batch key, so same-sender bursts could
  # never merge and channel-scoped debounce would never engage.
  defp message_thread_id(chat_id, message) do
    case optional_text(message, "root_id") || optional_text(message, "parent_id") do
      nil -> nil
      root_id -> provider_thread_id(chat_id, root_id)
    end
  end

  defp reply_target_id(message, source_entry_id) do
    case optional_text(message, "parent_id") || optional_text(message, "upper_message_id") ||
           optional_text(message, "root_id") do
      ^source_entry_id -> nil
      target_id -> target_id
    end
  end

  @doc false
  @spec signal_channel_id(String.t()) :: String.t()
  def signal_channel_id(chat_id), do: "lark:#{encode_id(chat_id)}"

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

  defp observe_card_operator(%{context: context, config: config}, operator_id) do
    attrs = %{
      provider: Map.get(config, "platformSubjectNamespace", "lark-main"),
      external_id: operator_id,
      uid: operator_id
    }

    case AdapterContext.observe_platform_subject(context, attrs) do
      {:ok, %{principal: principal}} -> {:ok, principal.uid}
      {:error, _reason} = error -> error
    end
  end

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
    value =
      case fetch_value(action, "value") do
        value when is_map(value) -> value
        _value -> action
      end

    case fetch_value(action, "form_value") do
      form_value when is_map(form_value) -> Map.put(value, "formValue", form_value)
      _form_value -> value
    end
  end

  defp action_value(_action), do: %{}

  defp mention_prefixes(mentions) do
    mentions
    |> Enum.flat_map(&mention_prefix_values/1)
    |> Enum.uniq()
    # Lark mention keys can share prefixes. Longest-first stripping prevents
    # "@_user_10 /retry" from being partially consumed as "@_user_1".
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp mention_prefix_values(mention) do
    key = optional_text(mention, "key")

    [key, at_prefixed_key(key), optional_text(mention, "name")]
    |> Enum.reject(&is_nil/1)
  end

  defp mention_placeholder_values(mention) do
    key = optional_text(mention, "key")

    [key, at_prefixed_key(key)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&String.length/1, :desc)
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

  defp required_text(map, key) do
    case optional_text(map, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:missing, key}}
    end
  end

  defp required_text_value(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp required_text_value(_value, key), do: {:error, {:missing, key}}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
