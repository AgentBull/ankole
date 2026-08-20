defmodule Ankole.Plugins.WeComAdapter.Inbound do
  @moduledoc """
  WeCom inbound normalization into SignalsGateway adapter APIs.

  A message callback (`aibot_msg_callback`) becomes an `emit_entry`; a
  `template_card_event` becomes an `emit_action`. The platform subject is
  `from.userid` — plaintext only when the bot was created by a corp super
  administrator, otherwise a stable encrypted id that still works for chat but
  never joins the directory (operator manual requirement).

  Attachments must be materialized before emit: callback media URLs live five
  minutes and their bytes are AES-encrypted with a per-item key, so bytes are
  pulled and decrypted immediately and the mirror never stores a URL or key.
  The frame `req_id` is recorded in channel metadata as the durable respond
  anchor — replies through `aibot_respond_msg` stay valid for 24 hours.

  A quoted message (`quote`) carries content but no id of the quoted entry, so
  quoted text renders as a deterministic leading quote block (the platform
  semantics translated into the only carrier available) and quoted media joins
  the attachments; the full quote stays in the raw payload.
  """

  alias Ankole.Logging
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.WorkerFiles
  alias WeComOpenAPI.Bot
  alias WeComOpenAPI.Bot.Event
  alias WeComOpenAPI.Media

  import MapHelpers,
    only: [collect_results: 1, compact_map: 1, fetch_value: 2, optional_text: 2]

  @managed_action_protocol "ankole.interactive_output.action.v1"
  @quote_prefix "> 引用："
  @quote_budget_bytes 500

  @doc "Builds the dispatcher consumer record for one SignalsGateway chat binding."
  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{
      kind: :chat,
      context: context,
      config: config
    }
  end

  @doc "Handles a message callback for all chat consumers."
  @spec handle_message_receive(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_message_receive(&1, event))
  end

  @doc "Handles a template-card event for all chat consumers."
  @spec handle_card_action(String.t(), Event.t(), [map()]) ::
          {:ok, list()} | {:error, term()}
  def handle_card_action(_event_type, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_card_action(&1, event))
  end

  @doc "Normalizes a message callback without submitting it. Main test seam."
  @spec normalize_message_receive(Event.t(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(%Event{body: payload, req_id: req_id}, %{
        context: %AdapterContext{},
        config: config
      })
      when is_map(payload) do
    with {:ok, source_entry_id} <- required_text(payload, "msgid"),
         {:ok, author} <- author(payload, config),
         {:ok, channel_kind, chat_target} <- channel_target(payload),
         raw_text <- message_text(payload),
         attachments <- attachments(payload),
         :ok <- material_message?(raw_text, attachments) do
      text =
        raw_text
        |> strip_leading_mention(channel_kind)
        |> prepend_quote(payload)
        |> blank_to_nil()

      {:ok,
       %{
         source_event_id: source_entry_id,
         source_entry_id: source_entry_id,
         signal_channel_id: signal_channel_id(chat_target),
         reply_to_source_entry_id: nil,
         provider_thread_id: nil,
         channel: %{
           kind: channel_kind,
           reply_mode: :channel,
           name: nil,
           metadata:
             compact_map(%{
               "chat_target" => chat_target,
               "chat_type" => optional_text(payload, "chattype"),
               "aibot_id" => optional_text(payload, "aibotid"),
               # Durable respond anchor: replies bound to this req_id work for
               # 24 hours. Channel metadata merges on every entry, so the
               # newest inbound always wins.
               "last_req_id" => req_id,
               "last_req_at" => DateTime.to_iso8601(DateTime.utc_now()),
               "dm_user_id" =>
                 if(channel_kind == :im_dm, do: optional_text(sender(payload), "userid"))
             }),
           raw_payload: compact_map(payload)
         },
         text: text,
         formatted_content: formatted_content(text),
         attachments: attachments,
         mentions: [],
         structured_mention_prefixes: [],
         # Group deliveries exist only for @-mentions (the platform delivers
         # nothing else), so every inbound message is explicit.
         explicit: true,
         author: author,
         metadata:
           compact_map(%{
             "provider" => "wecom",
             "message_type" => optional_text(payload, "msgtype"),
             "req_id" => req_id,
             "voice_transcript" => optional_text(payload, "msgtype") == "voice" || nil
           }),
         raw_payload: compact_map(payload),
         provider_time: provider_time(payload)
       }}
    end
  end

  def normalize_message_receive(_event, _consumer), do: {:error, :invalid_chat_consumer}

  defp emit_message_receive(%{context: %AdapterContext{} = context} = consumer, %Event{} = event) do
    case normalize_message_receive(event, consumer) do
      {:ok, input} ->
        with {:ok, input} <- materialize_attachments(input, consumer) do
          Ingress.emit_entry(context.agent_uid, context.binding_name, input)
        end

      {:ignore, reason} ->
        {:ok, %{status: ignored_status(reason), reason: reason}}

      {:error, _reason} = error ->
        error
    end
  end

  # --- card events ----------------------------------------------------------

  @doc "Normalizes a template-card event without observing or submitting it. Test seam."
  @spec normalize_card_action(Event.t()) :: {:ok, map()} | {:error, term()}
  def normalize_card_action(%Event{body: payload}) when is_map(payload) do
    event_body = card_event_body(payload)

    with {:ok, task_id} <- required_text(event_body, "task_id"),
         {:ok, operator_id} <- operator_actor_key(payload) do
      {:ok, channel_kind, chat_target} =
        case channel_target(payload) do
          {:ok, kind, target} -> {:ok, kind, target}
          _no_channel -> {:ok, :im_dm, operator_id}
        end

      value = action_value(event_body, task_id)
      action_id = card_action_id(task_id, value, operator_id)

      {:ok,
       %{
         source_event_id: action_id,
         action_id: action_id,
         signal_channel_id: signal_channel_id(chat_target),
         source_entry_id: task_id,
         provider_thread_id: nil,
         actor_event_type: "signal.action.invoked",
         action:
           compact_map(%{
             "name" => value["controlId"] || button_key(event_body) || "card_action",
             "value" => value,
             "operator_id" => operator_id,
             "task_id" => task_id
           }),
         channel_kind: channel_kind,
         raw_payload: compact_map(payload)
       }}
    end
  end

  def normalize_card_action(_event), do: {:error, :invalid_card_action}

  defp emit_card_action(%{context: %AdapterContext{} = context} = consumer, %Event{} = event) do
    case normalize_card_action(event) do
      {:ok, input} ->
        operator_id = input.action["operator_id"]

        with {:ok, operator_principal_uid} <- observe_card_operator(consumer, operator_id) do
          input =
            input
            |> Map.delete(:channel_kind)
            |> Map.update!(
              :action,
              &Map.put(&1, "operator_principal_uid", operator_principal_uid)
            )

          result = Ingress.emit_action(context.agent_uid, context.binding_name, input)
          acknowledge_card(consumer, event, input, result)
          result
        end

      {:error, :missing_operator_id} ->
        {:ok, %{status: :ignored_missing_operator}}

      # A payload that cannot name its card or operator will never become
      # valid; dropping it beats a redelivery loop.
      {:error, {:missing, _key}} ->
        {:ok, %{status: :ignored_invalid_card_action}}

      {:error, :invalid_card_action} ->
        {:ok, %{status: :ignored_invalid_card_action}}
    end
  end

  # The platform lets a card change only inside the 5-second event window
  # (`aibot_respond_update_msg` bound to the event req_id), so the settled
  # visual state must be written here, not from the session writer. The
  # replacement is a receipt card: original card payloads are not carried by
  # the event, and a settled interaction has no live controls to preserve.
  defp acknowledge_card(consumer, %Event{req_id: req_id} = _event, input, {:ok, _result})
       when is_binary(req_id) do
    receipt = %{
      "card_type" => "text_notice",
      "main_title" => %{"title" => "已收到"},
      "sub_title_text" => receipt_text(input.action["value"]),
      "task_id" => input.action["task_id"],
      "card_action" => %{"type" => 1, "url" => "https://work.weixin.qq.com"}
    }

    with {:ok, client} <- ConnectionOwner.bot_client(consumer.config),
         {:error, reason} <- Bot.update_template_card(client, req_id, receipt) do
      Logging.warning(
        "wecom_adapter.card.acknowledge_failed",
        "wecom template card acknowledge update failed",
        %{task_id: input.action["task_id"], reason: inspect(reason)}
      )
    else
      _ok_or_unavailable -> :ok
    end

    :ok
  end

  defp acknowledge_card(_consumer, _event, _input, _result), do: :ok

  defp receipt_text(%{"selectedOptionId" => option}) when is_binary(option), do: "已选择：#{option}"
  defp receipt_text(_value), do: "操作已受理"

  # Template-card buttons round-trip only their `key` string, so the portable
  # interaction protocol is packed into the key by `TemplateCard` and unpacked
  # here; `task_id` carries the source actor event. An unmanaged key stays a
  # bare value so foreign cards still produce an action.
  defp action_value(event_body, task_id) do
    key = button_key(event_body)

    case parse_managed_key(key) do
      {:ok, value} ->
        Map.put(value, "sourceActorEventId", task_source_actor_event_id(task_id))

      :unmanaged ->
        compact_map(%{"key" => key, "task_id" => task_id})
    end
  end

  @doc false
  @spec parse_managed_key(String.t() | nil) :: {:ok, map()} | :unmanaged
  def parse_managed_key("ank1|" <> rest) do
    case String.split(rest, "|") do
      [interaction_id, version, control_id, option_id, option_value] ->
        {:ok,
         %{
           "version" => @managed_action_protocol,
           "answerKind" => "choice",
           "interactionId" => interaction_id,
           "interactionVersion" => parse_integer(version),
           "controlId" => control_id,
           "selectedOptionId" => option_id,
           "optionValue" => option_value
         }}

      _other ->
        :unmanaged
    end
  end

  def parse_managed_key(_key), do: :unmanaged

  defp task_source_actor_event_id("ankole:" <> event_id), do: event_id
  defp task_source_actor_event_id(_task_id), do: nil

  defp button_key(event_body) do
    optional_text(event_body, "key") || optional_text(event_body, "button_key") ||
      optional_text(fetch_value(event_body, "button") || %{}, "key")
  end

  defp card_event_body(payload) do
    case fetch_value(payload, "event") do
      event when is_map(event) -> event
      _other -> payload
    end
  end

  # A managed press dedupes on its semantic identity; a foreign press falls
  # back to a content hash so two different presses never conflate.
  defp card_action_id(task_id, %{"version" => @managed_action_protocol} = value, _operator) do
    "card:#{task_id}:#{value["interactionId"]}:#{value["interactionVersion"]}:#{value["controlId"]}:#{value["selectedOptionId"]}"
  end

  defp card_action_id(task_id, value, operator) do
    "card:#{task_id}:#{operator}:#{:erlang.phash2(value)}"
  end

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> collect_results()
  end

  # --- author / platform subject -------------------------------------------

  defp sender(payload), do: fetch_value(payload, "from") || %{}

  defp author(payload, config) do
    case optional_text(sender(payload), "userid") do
      # System callbacks must never become a conversation subject.
      "sys" ->
        {:ignore, :system_sender}

      userid when is_binary(userid) ->
        {:ok,
         %{
           "id" => userid,
           "platform_subject" => userid,
           "display_name" => nil,
           "metadata" =>
             compact_map(%{
               "corp_id" => optional_text(sender(payload), "corpid"),
               "provider" => Map.get(config, "platformSubjectNamespace", "wecom-main")
             })
         }}

      nil ->
        {:ignore, :missing_platform_subject}
    end
  end

  defp observe_card_operator(_consumer, "sys"), do: {:error, :missing_operator_id}

  defp observe_card_operator(%{context: context, config: config}, operator_id) do
    attrs = %{
      provider: Map.get(config, "platformSubjectNamespace", "wecom-main"),
      external_id: operator_id,
      uid: operator_id
    }

    case AdapterContext.observe_platform_subject(context, attrs) do
      {:ok, %{principal: principal}} -> {:ok, principal.uid}
      {:error, _reason} = error -> error
    end
  end

  # --- channel --------------------------------------------------------------

  defp channel_target(payload) do
    case optional_text(payload, "chattype") do
      "group" ->
        case optional_text(payload, "chatid") do
          chatid when is_binary(chatid) -> {:ok, :im_group, chatid}
          nil -> {:ignore, :missing_group_chatid}
        end

      _single ->
        case optional_text(sender(payload), "userid") do
          userid when is_binary(userid) and userid != "sys" -> {:ok, :im_dm, userid}
          _missing -> {:ignore, :missing_platform_subject}
        end
    end
  end

  @doc false
  @spec signal_channel_id(String.t()) :: String.t()
  def signal_channel_id(chat_target), do: "wecom:#{encode_id(chat_target)}"

  defp encode_id(id), do: URI.encode(id, &URI.char_unreserved?/1)

  # --- text -----------------------------------------------------------------

  # Inbound text stays the user's own words. A voice message arrives as its
  # platform transcript only (no audio file exists in the callback), so the
  # transcript is the message text, flagged in metadata.
  defp message_text(payload) do
    case optional_text(payload, "msgtype") do
      "text" -> optional_text(fetch_value(payload, "text") || %{}, "content")
      "voice" -> optional_text(fetch_value(payload, "voice") || %{}, "content")
      "mixed" -> mixed_text(payload)
      _type -> nil
    end
  end

  defp mixed_text(payload) do
    payload
    |> mixed_items()
    |> Enum.map(fn item ->
      case fetch_value(item, "text") do
        %{"content" => content} when is_binary(content) -> content
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> blank_to_nil()
  end

  defp mixed_items(payload) do
    case fetch_value(payload, "mixed") do
      %{"msg_item" => items} when is_list(items) -> Enum.filter(items, &is_map/1)
      _other -> []
    end
  end

  # Group deliveries are @-mentions by definition, and the callback carries no
  # mention structure or bot display name — strip exactly one leading @-token.
  defp strip_leading_mention(nil, _kind), do: nil
  defp strip_leading_mention(text, :im_dm), do: text

  defp strip_leading_mention(text, :im_group) do
    String.replace(text, ~r/\A\s*@\S+\s*/u, "")
  end

  defp prepend_quote(text, payload) do
    case quoted_text(payload) do
      nil ->
        text

      quoted ->
        block = @quote_prefix <> truncate_utf8(quoted, @quote_budget_bytes)
        [block, text] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")
    end
  end

  defp quoted_text(payload) do
    quote_body = fetch_value(payload, "quote")

    if is_map(quote_body) do
      case optional_text(quote_body, "msgtype") do
        "text" -> optional_text(fetch_value(quote_body, "text") || %{}, "content")
        "voice" -> optional_text(fetch_value(quote_body, "voice") || %{}, "content")
        "mixed" -> mixed_text(%{"mixed" => fetch_value(quote_body, "mixed")})
        _other -> nil
      end
    end
  end

  defp truncate_utf8(text, budget) when byte_size(text) <= budget, do: text

  defp truncate_utf8(text, budget) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      candidate = acc <> grapheme

      if byte_size(candidate) > budget do
        {:halt, acc}
      else
        {:cont, candidate}
      end
    end)
    |> Kernel.<>("…")
  end

  defp material_message?(text, _attachments) when is_binary(text) and text != "", do: :ok
  defp material_message?(_text, [_ | _]), do: :ok
  defp material_message?(_text, _attachments), do: {:ignore, :empty_or_unsupported_message}

  defp formatted_content(nil), do: %{}
  defp formatted_content(text), do: %{"format" => "markdown", "body" => text}

  # --- attachments ----------------------------------------------------------

  defp attachments(payload) do
    own =
      case optional_text(payload, "msgtype") do
        "image" -> [resource_attachment("image", fetch_value(payload, "image"))]
        "file" -> [resource_attachment("file", fetch_value(payload, "file"))]
        "video" -> [resource_attachment("video", fetch_value(payload, "video"))]
        "mixed" -> mixed_attachments(payload)
        _type -> []
      end

    (own ++ quote_attachments(payload))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["provider_ref"])
  end

  defp mixed_attachments(payload) do
    payload
    |> mixed_items()
    |> Enum.map(fn item ->
      case fetch_value(item, "image") do
        image when is_map(image) -> resource_attachment("image", image)
        _other -> nil
      end
    end)
  end

  defp quote_attachments(payload) do
    quote_body = fetch_value(payload, "quote")

    if is_map(quote_body) do
      case optional_text(quote_body, "msgtype") do
        "image" -> [resource_attachment("image", fetch_value(quote_body, "image"))]
        "file" -> [resource_attachment("file", fetch_value(quote_body, "file"))]
        "video" -> [resource_attachment("video", fetch_value(quote_body, "video"))]
        "mixed" -> mixed_attachments(%{"mixed" => fetch_value(quote_body, "mixed")})
        _other -> []
      end
    else
      []
    end
  end

  defp resource_attachment(type, source) when is_map(source) do
    case optional_text(source, "url") do
      url when is_binary(url) ->
        compact_map(%{
          "provider_ref" =>
            "wecom:#{type}:#{:erlang.phash2({url, optional_text(source, "aeskey")})}",
          "provider" => "wecom",
          "temp_url" => url,
          "aeskey" => optional_text(source, "aeskey"),
          "resource_type" => type,
          "name" => optional_text(source, "filename") || optional_text(source, "name")
        })

      nil ->
        nil
    end
  end

  defp resource_attachment(_type, _source), do: nil

  defp materialize_attachments(%{attachments: []} = input, _consumer), do: {:ok, input}

  defp materialize_attachments(%{attachments: attachments} = input, %{
         context: %{agent_uid: agent_uid}
       }) do
    materialized = Enum.map(attachments, &materialize_attachment(&1, agent_uid))
    {:ok, %{input | attachments: materialized}}
  end

  # The five-minute URL and its key must never outlive this call: success
  # stores plaintext bytes under a durable path, failure keeps only an inert
  # descriptor. Media without an aeskey is not expected (design fact); treat it
  # as a failed materialization rather than storing undecryptable bytes.
  defp materialize_attachment(%{"temp_url" => url} = attachment, agent_uid)
       when is_binary(url) do
    result =
      case attachment["aeskey"] do
        aeskey when is_binary(aeskey) -> Media.download(url, aeskey)
        _missing -> {:error, :media_aeskey_missing}
      end

    case result do
      {:ok, %{body: body, filename: filename}} ->
        name = attachment["name"] || filename || "attachment"
        relative_path = materialized_relative_path(attachment, name)
        lane_path = Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative_path)

        case WorkerFiles.put("user_files", lane_path, body) do
          {:ok, result} ->
            attachment
            |> Map.drop(["temp_url", "aeskey"])
            |> Map.put(
              "agent_computer_path",
              Path.join(Ankole.AgentHomePaths.user_files(agent_uid), relative_path)
            )
            |> Map.put("user_files_relative_path", relative_path)
            |> Map.put("name", name)
            |> MapHelpers.maybe_put("xxh3_128", result["xxh3_128"])
            |> MapHelpers.maybe_put("size", result["size"])

          {:error, reason} ->
            log_materialization_skip(attachment, reason)
            Map.drop(attachment, ["temp_url", "aeskey"])
        end

      {:error, reason} ->
        log_materialization_skip(attachment, reason)
        Map.drop(attachment, ["temp_url", "aeskey"])
    end
  rescue
    error ->
      log_materialization_skip(attachment, error)
      Map.drop(attachment, ["temp_url", "aeskey"])
  end

  defp materialize_attachment(attachment, _agent_uid), do: attachment

  defp log_materialization_skip(attachment, reason) do
    Logging.warning(
      "wecom_adapter.attachment.materialization_skipped",
      "wecom attachment materialization skipped",
      %{provider_ref: attachment["provider_ref"], reason: inspect(reason)}
    )
  end

  defp materialized_relative_path(attachment, name) do
    Path.join([
      "inbox",
      "wecom",
      sanitize_segment(attachment["provider_ref"]),
      sanitize_segment(name)
    ])
  end

  defp sanitize_segment(value) when is_binary(value) do
    value
    |> Ankole.Kernel.any_ascii()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unnamed"
      segment -> String.slice(segment, 0, 160)
    end
  end

  defp sanitize_segment(_value), do: "unnamed"

  # --- helpers --------------------------------------------------------------

  defp provider_time(payload) do
    case fetch_value(payload, "create_time") do
      value when is_integer(value) ->
        unit = if value > 10_000_000_000, do: :millisecond, else: :second
        DateTime.from_unix!(value, unit)

      _value ->
        nil
    end
  end

  defp operator_actor_key(payload) do
    case optional_text(sender(payload), "userid") do
      "sys" -> {:error, :missing_operator_id}
      userid when is_binary(userid) -> {:ok, userid}
      nil -> {:error, :missing_operator_id}
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> 0
    end
  end

  defp ignored_status(:missing_platform_subject), do: :ignored_missing_platform_subject
  defp ignored_status(:system_sender), do: :ignored_system_sender
  defp ignored_status(:missing_group_chatid), do: :ignored_missing_group_chatid
  defp ignored_status(:empty_or_unsupported_message), do: :ignored_empty_or_unsupported_message

  defp required_text(map, key) do
    case optional_text(map, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:missing, key}}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
