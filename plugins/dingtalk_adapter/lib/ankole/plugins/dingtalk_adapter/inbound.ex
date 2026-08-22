defmodule Ankole.Plugins.DingTalkAdapter.Inbound do
  @moduledoc """
  DingTalk inbound normalization into SignalsGateway adapter APIs.

  The robot message CALLBACK (`/v1.0/im/bot/messages/get`) becomes an
  `emit_entry`; the card CALLBACK (`/v1.0/card/instances/callback`) becomes an
  `emit_action`. The platform subject is the enterprise `senderStaffId` — a
  message without one (external group member, unpublished app) is fail-closed
  and ignored rather than mapped onto an unactionable encrypted id.

  Attachments must be materialized before emit: DingTalk `downloadCode` values
  resolve to short-lived URLs, so bytes are pulled immediately and the mirror
  never stores a `downloadCode` or temporary URL.
  """

  alias Ankole.Logging
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.WorkerFiles
  alias DingTalkOpenAPI.Event
  alias DingTalkOpenAPI.Robot

  import MapHelpers,
    only: [collect_results: 1, compact_map: 1, fetch_value: 2, optional_text: 2]

  @managed_action_protocol "ankole.interactive_output.action.v1"

  @doc "Builds the dispatcher consumer record for one SignalsGateway chat binding."
  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{
      kind: :chat,
      context: context,
      config: config
    }
  end

  @doc "Handles a robot message CALLBACK for all chat consumers."
  @spec handle_message_receive(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_topic, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_message_receive(&1, event))
  end

  @doc "Handles a card action CALLBACK for all chat consumers."
  @spec handle_card_action(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_topic, %Event{} = event, consumers) do
    dispatch_chat(consumers, &emit_card_action(&1, event))
  end

  @doc "Normalizes a message CALLBACK without submitting it. Main test seam."
  @spec normalize_message_receive(Event.t(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(%Event{data: payload}, %{
        context: %AdapterContext{},
        config: config
      })
      when is_map(payload) do
    with {:ok, source_entry_id} <- required_text(payload, "msgId"),
         {:ok, conversation_id} <- required_text(payload, "conversationId"),
         {:ok, author} <- author(payload, config),
         raw_text <- message_text(payload),
         attachments <- attachments(payload),
         :ok <- material_message?(raw_text, attachments),
         channel_kind <- channel_kind(payload),
         explicit <- explicit?(channel_kind, payload),
         text <-
           visible_text(raw_text, explicit and strip_leading_mention?(channel_kind, payload)),
         provider_time <- provider_time(payload) do
      {:ok,
       %{
         source_event_id: source_entry_id,
         source_entry_id: source_entry_id,
         signal_channel_id: signal_channel_id(conversation_id),
         reply_to_source_entry_id: nil,
         provider_thread_id: nil,
         channel: %{
           kind: channel_kind,
           reply_mode: :channel,
           name: optional_text(payload, "conversationTitle"),
           metadata:
             compact_map(%{
               "conversation_id" => conversation_id,
               "conversation_type" => optional_text(payload, "conversationType"),
               "robot_code" => optional_text(payload, "robotCode"),
               # DM sends need the counterpart userid; the group path uses the
               # conversation id directly, so only record it for one-to-one chats.
               "dm_user_id" =>
                 if(channel_kind == :im_dm, do: optional_text(payload, "senderStaffId"))
             }),
           raw_payload: compact_map(payload)
         },
         text: text,
         formatted_content: formatted_content(text),
         attachments: attachments,
         mentions: [],
         structured_mention_prefixes: [],
         explicit: explicit,
         author: author,
         metadata:
           compact_map(%{
             "provider" => "dingtalk",
             "message_type" => optional_text(payload, "msgtype"),
             "corp_id" => optional_text(payload, "senderCorpId"),
             "is_admin" => fetch_value(payload, "isAdmin")
           }),
         raw_payload: compact_map(payload),
         provider_time: provider_time
       }}
    end
  end

  def normalize_message_receive(_event, _consumer), do: {:error, :invalid_chat_consumer}

  defp emit_message_receive(%{context: %AdapterContext{} = context} = consumer, %Event{} = event) do
    case normalize_message_receive(event, consumer) do
      {:ok, input} ->
        with {:ok, input} <- maybe_materialize_attachments(input, consumer) do
          Ingress.emit_entry(context.agent_uid, context.binding_name, input)
        end

      {:ignore, reason} ->
        {:ok, %{status: ignored_status(reason), reason: reason}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Normalizes a card CALLBACK without observing or submitting it. Test seam."
  @spec normalize_card_action(Event.t()) :: {:ok, map()} | {:error, term()}
  def normalize_card_action(%Event{data: payload}) when is_map(payload) do
    with {:ok, out_track_id} <- required_text(payload, "outTrackId"),
         {:ok, operator_id} <- operator_actor_key(operator_user_id(payload)) do
      conversation_id =
        optional_text(payload, "openConversationId") || optional_text(payload, "conversationId") ||
          out_track_id

      value = action_value(payload)
      action_id = card_action_id(payload, out_track_id, value)

      {:ok,
       %{
         source_event_id: action_id,
         action_id: action_id,
         signal_channel_id: signal_channel_id(conversation_id),
         source_entry_id: out_track_id,
         provider_thread_id: nil,
         actor_event_type: "signal.action.invoked",
         action:
           compact_map(%{
             "name" => card_action_name(payload, value),
             "value" => value,
             "operator_id" => operator_id,
             "out_track_id" => out_track_id
           }),
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
            Map.update!(
              input,
              :action,
              &Map.put(&1, "operator_principal_uid", operator_principal_uid)
            )

          Ingress.emit_action(context.agent_uid, context.binding_name, input)
        end

      {:error, :missing_operator_id} ->
        {:ok, %{status: :ignored_missing_operator}}

      # A payload that cannot name its card or operator will never become
      # valid; acking it as ignored beats an endless redelivery loop.
      {:error, :invalid_card_action} ->
        {:ok, %{status: :ignored_invalid_card_action}}

      {:error, {:missing, _key}} ->
        {:ok, %{status: :ignored_invalid_card_action}}
    end
  end

  # A managed callback (the portable interaction protocol) dedupes on its
  # semantic identity — the same control on the same interaction version is one
  # logical answer no matter how often the platform redelivers it. Non-managed
  # callbacks fall back to a content hash so two *different* presses on one card
  # are never conflated into a single actor event.
  defp card_action_id(payload, out_track_id, value) do
    case optional_text(payload, "cardActionId") do
      action_id when is_binary(action_id) ->
        action_id

      nil ->
        case value do
          %{
            "version" => @managed_action_protocol,
            "interactionId" => interaction_id,
            "interactionVersion" => version,
            "controlId" => control_id
          } ->
            option = optional_text(value, "selectedOptionId") || "input"
            "card:#{out_track_id}:#{interaction_id}:#{version}:#{control_id}:#{option}"

          _unmanaged ->
            "card:#{out_track_id}:#{:erlang.phash2(value)}"
        end
    end
  end

  defp card_action_name(payload, value) do
    optional_text(payload, "actionId") || first_action_id(payload) ||
      optional_text(value, "controlId") || "card_action"
  end

  defp first_action_id(payload) do
    payload
    |> card_private_data()
    |> fetch_value("actionIds")
    |> case do
      [action_id | _rest] when is_binary(action_id) -> action_id
      _other -> nil
    end
  end

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> collect_results()
  end

  # --- author / platform subject -------------------------------------------

  defp author(payload, config) do
    case optional_text(payload, "senderStaffId") do
      staff_id when is_binary(staff_id) ->
        {:ok,
         %{
           "id" => staff_id,
           "platform_subject" => staff_id,
           "display_name" => optional_text(payload, "senderNick"),
           "metadata" =>
             compact_map(%{
               "union_id" => optional_text(payload, "senderUnionId"),
               "corp_id" => optional_text(payload, "senderCorpId"),
               "is_admin" => fetch_value(payload, "isAdmin"),
               "provider" => Map.get(config, "platformSubjectNamespace", "dingtalk-main")
             })
         }}

      nil ->
        {:ignore, :missing_platform_subject}
    end
  end

  defp observe_card_operator(%{context: context, config: config}, operator_id) do
    attrs = %{
      provider: Map.get(config, "platformSubjectNamespace", "dingtalk-main"),
      external_id: operator_id
    }

    case AdapterContext.observe_platform_subject(context, attrs) do
      {:ok, %{principal: principal}} -> {:ok, principal.uid}
      {:error, _reason} = error -> error
    end
  end

  # --- text ----------------------------------------------------------------

  # Inbound text stays the user's own words. A voice message has no typed text —
  # its platform ASR transcript rides the attachment descriptor (`recognition`)
  # for the model to read without fabricating it into the mirror as user prose.
  defp message_text(payload) do
    case optional_text(payload, "msgtype") do
      "text" -> optional_text(fetch_value(payload, "text") || %{}, "content")
      "richText" -> rich_text(payload)
      _type -> nil
    end
  end

  defp rich_text(payload) do
    payload
    |> fetch_value("content")
    |> case do
      %{"richText" => segments} when is_list(segments) -> segments
      _other -> []
    end
    # Keep segment text verbatim (interior spaces are meaningful); only the
    # joined result is blanked. optional_text would trim each segment and glue
    # words together.
    |> Enum.map(&segment_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> MapHelpers.blank_to_nil()
  end

  defp segment_text(segment) do
    case fetch_value(segment, "text") do
      text when is_binary(text) -> text
      _other -> nil
    end
  end

  # DingTalk metadata already flags the @ via isInAtList, but some clients still
  # prefix the visible text with "@<bot> ". The payload never carries the bot's
  # display name, so a leading @-token is stripped only when the at-list
  # positively attributes it to the bot alone — a message opening with
  # "@somebody-else" keeps its text intact.
  defp visible_text(nil, _strip), do: nil

  defp visible_text(text, true) when is_binary(text) do
    text
    |> String.replace(~r/\A\s*@\S+\s+/u, "")
    |> MapHelpers.blank_to_nil()
  end

  defp visible_text(text, _strip), do: MapHelpers.blank_to_nil(text)

  defp strip_leading_mention?(:im_dm, _payload), do: false

  defp strip_leading_mention?(:im_group, payload) do
    chatbot_user_id = optional_text(payload, "chatbotUserId")

    case fetch_value(payload, "atUsers") do
      at_users when is_list(at_users) and at_users != [] ->
        Enum.all?(at_users, fn at_user ->
          is_map(at_user) and is_binary(chatbot_user_id) and
            optional_text(at_user, "dingtalkId") == chatbot_user_id
        end)

      _missing ->
        false
    end
  end

  defp material_message?(text, _attachments) when is_binary(text), do: :ok
  defp material_message?(nil, [_ | _]), do: :ok
  defp material_message?(_text, _attachments), do: {:ignore, :empty_or_unsupported_message}

  defp formatted_content(nil), do: %{}
  defp formatted_content(text), do: %{"format" => "markdown", "body" => text}

  # --- attachments ---------------------------------------------------------

  defp attachments(payload) do
    case optional_text(payload, "msgtype") do
      type when type in ["picture", "image"] -> [resource_attachment("image", payload)]
      "audio" -> [resource_attachment("audio", payload)]
      "video" -> [resource_attachment("video", payload)]
      "file" -> [resource_attachment("file", payload)]
      "richText" -> rich_text_attachments(payload)
      _type -> []
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["provider_ref"])
  end

  defp rich_text_attachments(payload) do
    payload
    |> fetch_value("content")
    |> case do
      %{"richText" => segments} when is_list(segments) -> segments
      _other -> []
    end
    |> Enum.map(fn segment ->
      case optional_text(segment, "downloadCode") do
        nil -> nil
        _code -> resource_attachment("image", segment)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp resource_attachment(type, source) do
    case optional_text(source, "downloadCode") do
      code when is_binary(code) ->
        compact_map(%{
          "provider_ref" => "dingtalk:#{type}:#{:erlang.phash2(code)}",
          "provider" => "dingtalk",
          "download_code" => code,
          "resource_type" => type,
          "name" => optional_text(source, "fileName"),
          "duration" => fetch_value(source, "duration"),
          "recognition" => optional_text(source, "recognition")
        })

      nil ->
        nil
    end
  end

  defp maybe_materialize_attachments(%{attachments: []} = input, _consumer), do: {:ok, input}

  defp maybe_materialize_attachments(%{attachments: attachments} = input, %{
         config: config,
         context: %{agent_uid: agent_uid}
       }) do
    client = Config.client(config)
    robot_code = Config.effective_robot_code(config)

    materialized =
      Enum.map(attachments, &materialize_attachment(&1, client, robot_code, agent_uid))

    {:ok, %{input | attachments: materialized}}
  end

  defp materialize_attachment(
         %{"download_code" => code} = attachment,
         client,
         robot_code,
         agent_uid
       )
       when is_binary(code) do
    case Robot.download_message_file(client, robot_code, code) do
      {:ok, %{body: body, filename: filename}} ->
        name = attachment["name"] || filename || "attachment"
        relative_path = materialized_relative_path(attachment, name)

        lane_path = Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative_path)

        case WorkerFiles.put("user_files", lane_path, body) do
          {:ok, result} ->
            attachment
            |> Map.drop(["download_code"])
            |> Map.put(
              "agent_computer_path",
              Path.join(Ankole.AgentHomePaths.user_files(agent_uid), relative_path)
            )
            |> Map.put("user_files_relative_path", relative_path)
            |> MapHelpers.put_present("xxh3_128", result["xxh3_128"])
            |> MapHelpers.put_present("size", result["size"])

          {:error, reason} ->
            log_materialization_skip(attachment, reason)
            Map.drop(attachment, ["download_code"])
        end

      {:error, reason} ->
        log_materialization_skip(attachment, reason)
        Map.drop(attachment, ["download_code"])
    end
  rescue
    error ->
      log_materialization_skip(attachment, error)
      Map.drop(attachment, ["download_code"])
  end

  defp materialize_attachment(attachment, _client, _robot_code, _agent_uid), do: attachment

  defp log_materialization_skip(attachment, reason) do
    Logging.warning(
      "dingtalk_adapter.attachment.materialization_skipped",
      "dingtalk attachment materialization skipped",
      %{provider_ref: attachment["provider_ref"], reason: inspect(reason)}
    )
  end

  defp materialized_relative_path(attachment, name) do
    Path.join([
      "inbox",
      "dingtalk",
      WorkerFiles.sanitize_path_segment(attachment["provider_ref"]),
      WorkerFiles.sanitize_path_segment(name)
    ])
  end

  # --- channel / helpers ---------------------------------------------------

  defp channel_kind(payload) do
    case optional_text(payload, "conversationType") do
      "1" -> :im_dm
      _other -> :im_group
    end
  end

  defp explicit?(:im_dm, _payload), do: true
  defp explicit?(:im_group, payload), do: truthy?(fetch_value(payload, "isInAtList"))

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  @doc false
  @spec signal_channel_id(String.t()) :: String.t()
  def signal_channel_id(conversation_id), do: "dingtalk:#{encode_id(conversation_id)}"

  defp encode_id(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp provider_time(payload) do
    case fetch_value(payload, "createAt") do
      value when is_integer(value) ->
        unit = if value > 10_000_000_000, do: :millisecond, else: :second
        DateTime.from_unix!(value, unit)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> provider_time(%{"createAt" => integer})
          _other -> nil
        end

      _value ->
        nil
    end
  end

  defp operator_user_id(payload) do
    optional_text(payload, "userId") || optional_text(payload, "operatorUserId") ||
      optional_text(fetch_value(payload, "operator") || %{}, "userId")
  end

  defp operator_actor_key(value) when is_binary(value) and value != "", do: {:ok, value}
  defp operator_actor_key(_value), do: {:error, :missing_operator_id}

  # Card STREAM callback payloads nest the button's configured params under
  # `content` (a JSON string) → `cardPrivateData` → `params`; tolerate the bare
  # shapes too since the exact field set is smoke-test pending (design §13.10).
  # A managed protocol value gets its integer fields coerced here — template
  # param passthrough may stringify numbers, and the gateway contract requires a
  # real integer `interactionVersion`.
  defp action_value(payload) do
    params =
      payload
      |> card_private_data()
      |> fetch_value("params")

    case params do
      value when is_map(value) ->
        coerce_managed_value(value)

      _other ->
        case fetch_value(payload, "params") do
          value when is_map(value) -> coerce_managed_value(value)
          _missing -> compact_map(%{"content" => optional_text(payload, "content")})
        end
    end
  end

  defp card_private_data(payload) do
    content =
      case fetch_value(payload, "content") do
        value when is_map(value) -> value
        value when is_binary(value) -> decode_json_map(value)
        _other -> %{}
      end

    case fetch_value(content, "cardPrivateData") || fetch_value(payload, "cardPrivateData") do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp decode_json_map(value) do
    case Torque.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp coerce_managed_value(%{"version" => @managed_action_protocol} = value) do
    Map.update(value, "interactionVersion", 0, &coerce_integer/1)
  end

  defp coerce_managed_value(value), do: value

  defp coerce_integer(value) when is_integer(value), do: value

  defp coerce_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp coerce_integer(value), do: value

  defp ignored_status(:missing_platform_subject), do: :ignored_missing_platform_subject
  defp ignored_status(:empty_or_unsupported_message), do: :ignored_empty_or_unsupported_message

  defp required_text(map, key) do
    case optional_text(map, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:missing, key}}
    end
  end
end
