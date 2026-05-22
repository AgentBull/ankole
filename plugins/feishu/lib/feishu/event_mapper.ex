defmodule Feishu.EventMapper do
  @moduledoc false

  alias Feishu.{ContentMapper, DirectCommand, Source, UserInfo}
  alias FeishuOpenAPI.{CardAction, Event}

  import BullX.Utils.Map, only: [maybe_put: 3, reject_nil_values: 1]

  @message_receive "im.message.receive_v1"
  @message_updated "im.message.updated_v1"
  @message_recalled "im.message.recalled_v1"
  @reaction_created "im.message.reaction.created_v1"
  @reaction_deleted "im.message.reaction.deleted_v1"

  @spec map(term(), Source.t()) ::
          {:ok, map()} | {:direct_command, map()} | {:ignore, atom()} | {:error, map()}
  def map(%Event{} = event, %Source{} = source), do: map_event(event.type, event, source)
  def map(%CardAction{} = action, %Source{} = source), do: map_card_action(action, source)

  def map({:event, event_type, %Event{} = event}, %Source{} = source),
    do: map_event(event_type, event, source)

  def map({:card_action, %CardAction{} = action}, %Source{} = source),
    do: map_card_action(action, source)

  def map(%{} = payload, %Source{} = source) do
    payload |> Event.from_envelope() |> map(source)
  end

  @spec map_event(String.t(), Event.t(), Source.t()) ::
          {:ok, map()} | {:direct_command, map()} | {:ignore, atom()} | {:error, map()}
  def map_event(@message_receive, %Event{} = event, %Source{} = source) do
    with {:ok, env} <- common_event_env(event, source),
         :ok <- reject_self_sent(env, source),
         {:ok, blocks} <- ContentMapper.from_message(env.message, source),
         text <- ContentMapper.primary_text(blocks),
         {:ok, actor} <- actor_from_sender(env.sender, source),
         profile <- profile_from_sender(env.sender),
         account_input <- account_input(source, actor.id, profile, env),
         attention <- attention_decision(env, source),
         {:listen, :emit} <- {:listen, listen_admission(attention, source)},
         context <- context(env, actor, blocks, account_input) do
      maybe_message_or_command(text, env, actor, blocks, context, source, attention)
    else
      {:listen, :ignore} -> {:ignore, :unaddressed_group_message}
      other -> other
    end
  end

  def map_event(@message_updated, %Event{} = event, %Source{} = source) do
    with {:ok, env} <- common_event_env(event, source),
         :ok <- reject_self_sent(env, source),
         {:ok, blocks} <- ContentMapper.from_message(env.message, source),
         {:ok, actor} <- actor_from_sender(env.sender, source),
         account_input <- account_input(source, actor.id, profile_from_sender(env.sender), env),
         attention <- attention_decision(env, source) do
      {:ok,
       %{
         attrs:
           attrs(
             source,
             env,
             actor,
             blocks,
             "bullx.message.edited",
             attention_facts(attention, source)
           ),
         account_input: account_input,
         context: context(env, actor, blocks, account_input)
       }}
    end
  end

  def map_event(@message_recalled, %Event{} = event, %Source{} = source) do
    with {:ok, env} <- common_event_env(event, source),
         {:ok, actor} <- actor_from_sender(env.sender, source),
         account_input <- account_input(source, actor.id, profile_from_sender(env.sender), env) do
      blocks = [%{"type" => "text", "text" => "[message recalled]"}]

      {:ok,
       %{
         attrs: attrs(source, env, actor, blocks, "bullx.message.recalled", %{}),
         account_input: account_input,
         context: context(env, actor, blocks, account_input)
       }}
    end
  end

  def map_event(type, %Event{} = event, %Source{} = source)
      when type in [@reaction_created, @reaction_deleted] do
    with {:ok, env} <- common_event_env(event, source),
         {:ok, actor} <- actor_from_sender(env.sender, source),
         account_input <- account_input(source, actor.id, profile_from_sender(env.sender), env),
         emoji when is_binary(emoji) and emoji != "" <- reaction_emoji(env.raw_event) do
      action = if type == @reaction_created, do: "added", else: "removed"
      blocks = [%{"type" => "text", "text" => ":#{emoji}:"}]

      {:ok,
       %{
         attrs:
           attrs(source, env, actor, blocks, "bullx.reaction.changed", %{
             "reaction_action" => action,
             "emoji" => emoji
           }),
         account_input: account_input,
         context: context(env, actor, blocks, account_input)
       }}
    else
      nil -> {:error, Feishu.Error.payload("Feishu reaction event is missing emoji")}
      "" -> {:error, Feishu.Error.payload("Feishu reaction event is missing emoji")}
      error -> error
    end
  end

  def map_event("app_ticket", %Event{}, %Source{}), do: {:ignore, :sdk_lifecycle_event}
  def map_event(_type, %Event{}, %Source{}), do: {:ignore, :unhandled_event}

  @spec map_card_action(CardAction.t(), Source.t()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, map()}
  def map_card_action(%CardAction{} = action, %Source{} = source) do
    with {:ok, actor} <-
           actor_from_ids(
             %{"open_id" => action.open_id, "user_id" => action.user_id},
             source
           ),
         action_id <- action_id(action),
         env <- card_env(action, source, actor, action_id),
         account_input <- account_input(source, actor.id, profile_from_card(action), env) do
      blocks = action_blocks(action, action_id)

      {:ok,
       %{
         attrs:
           attrs(source, env, actor, blocks, "bullx.action.submitted", %{
             "action_id" => action_id,
             "action_actor_open_id" => actor.open_id
           }),
         account_input: account_input,
         context: context(env, actor, blocks, account_input)
       }}
    end
  end

  defp maybe_message_or_command(text, env, actor, blocks, context, source, attention) do
    case parse_command_text(text, attention) do
      {:ignore, reason} ->
        {:ignore, reason}

      {:ok, %{name: name} = parsed} when name in ["preauth", "webauth"] ->
        {:direct_command,
         Map.merge(parsed, %{
           event_id: env.event_id,
           source_id: source.id,
           chat_id: env.chat_id,
           chat_type: env.chat_type,
           thread_id: env.thread_id,
           message_id: env.message_id,
           actor: actor,
           account_input: context.account_input,
           reply_channel: reply_channel(source, env)
         })}

      {:ok, %{name: name, args: args} = parsed} ->
        {:ok,
         %{
           attrs:
             attrs(source, env, actor, blocks, "bullx.command.invoked", %{
               "command_name" => name,
               "command_surface" => Map.get(parsed, :surface, "slash_text"),
               "command_args_kind" => command_args_kind(args),
               "attention_reason" => command_attention_reason(parsed)
             }),
           account_input: context.account_input,
           context: context
         }}

      :error ->
        event_type = im_message_event_type(attention)

        {:ok,
         %{
           attrs:
             attrs(
               source,
               env,
               actor,
               blocks,
               event_type,
               attention_facts(attention, source)
             ),
           account_input: context.account_input,
           context: context
         }}
    end
  end

  defp parse_command_text(text, {:ambient, _reason}) do
    case DirectCommand.parse(text) do
      {:ok, _parsed} -> {:ignore, :unaddressed_group_command}
      :error -> :error
    end
  end

  defp parse_command_text(text, attention) do
    case DirectCommand.parse(text) do
      {:ok, parsed} ->
        {:ok, Map.put_new(parsed, :surface, "slash_text")}

      :error ->
        parse_mentioned_command_text(text, attention)
    end
  end

  defp parse_mentioned_command_text(text, {:addressed, "mention"}),
    do: DirectCommand.parse_mentioned_text(text)

  defp parse_mentioned_command_text(_text, _attention), do: :error

  defp command_attention_reason(%{surface: "mention_text"}), do: "mention_text"
  defp command_attention_reason(_parsed), do: "leading_slash"

  defp attention_decision(env, %Source{}) do
    cond do
      env.chat_type == "p2p" ->
        {:addressed, "dm"}

      provider_mentions?(env) ->
        {:addressed, "mention"}

      true ->
        {:ambient, "unaddressed"}
    end
  end

  defp listen_admission({:addressed, _reason}, _source), do: :emit

  defp listen_admission({:ambient, _reason}, %Source{im_listen_mode: :all_messages}), do: :emit
  defp listen_admission({:ambient, _reason}, _source), do: :ignore

  defp im_message_event_type({:addressed, _reason}), do: "bullx.im.message.addressed"
  defp im_message_event_type({:ambient, _reason}), do: "bullx.im.message.ambient"

  defp attention_facts({_decision, reason}, %Source{} = source) do
    %{
      "attention_reason" => reason,
      "im_listen_mode" => Atom.to_string(source.im_listen_mode)
    }
  end

  defp provider_mentions?(%{message: message}) do
    case Feishu.Mentions.parse_mentions(message, nil) do
      [_ | _] -> true
      [] -> false
    end
  end

  defp provider_mentions?(_env), do: false

  defp common_event_env(%Event{} = event, %Source{} = source) do
    raw_event = event.content || %{}
    message = Map.get(raw_event, "message") || raw_event
    sender = Map.get(raw_event, "sender") || Map.get(raw_event, "operator") || %{}

    chat_id =
      Map.get(message, "chat_id") ||
        Map.get(raw_event, "chat_id") ||
        Map.get(raw_event, "open_chat_id")

    message_id =
      Map.get(message, "message_id") ||
        Map.get(message, "open_message_id") ||
        Map.get(raw_event, "message_id") ||
        Map.get(raw_event, "open_message_id")

    case present?(chat_id) and present?(message_id) do
      true ->
        {:ok,
         %{
           event: event,
           raw_event: raw_event,
           event_id: event.id || message_id,
           event_type: event.type,
           tenant_key: event.tenant_key || Map.get(raw_event, "tenant_key") || source.tenant_key,
           app_id: event.app_id || source.app_id,
           message: message,
           sender: sender,
           chat_id: chat_id,
           chat_type: Map.get(message, "chat_type") || Map.get(raw_event, "chat_type"),
           message_id: message_id,
           open_message_id:
             Map.get(message, "open_message_id") || Map.get(raw_event, "open_message_id"),
           thread_id: Map.get(message, "thread_id"),
           reply_to_external_id: Map.get(message, "parent_id") || Map.get(message, "root_id")
         }}

      false ->
        {:error, Feishu.Error.payload("Feishu event is missing chat_id or message_id")}
    end
  end

  defp card_env(%CardAction{} = action, %Source{} = source, actor, action_id) do
    %{
      event: nil,
      raw_event: action.raw,
      event_id: card_action_event_id(action, actor, action_id),
      event_type: "card.action.trigger",
      tenant_key: action.tenant_key || source.tenant_key,
      app_id: source.app_id,
      chat_id: action.open_chat_id || "unknown",
      chat_type: nil,
      message_id: action.open_message_id || "unknown",
      open_message_id: action.open_message_id,
      thread_id: nil,
      reply_to_external_id: action.open_message_id
    }
  end

  defp reject_self_sent(%{sender: %{"sender_type" => "bot"}}, %Source{}),
    do: {:ignore, :self_sent_bot_message}

  defp reject_self_sent(%{sender: _sender}, %Source{}), do: :ok

  defp attrs(%Source{} = source, env, actor, blocks, event_type, extra_facts) do
    %{
      id: env.event_id,
      source: source_uri(source, env),
      type: event_type,
      time: event_time(env.event),
      subject: "feishu:chat:" <> env.chat_id,
      data: %{
        content: blocks,
        channel: %{adapter: "feishu", id: source.id, kind: channel_kind(env.chat_type)},
        scope: %{id: env.chat_id, thread_id: env.thread_id},
        actor: event_actor(actor),
        refs: refs(env),
        reply_channel: reply_channel(source, env),
        routing_facts: routing_facts(source, env, blocks, extra_facts),
        raw_ref: raw_ref(env)
      }
    }
  end

  defp source_uri(%Source{} = source, env) do
    tenant = env.tenant_key || source.tenant_key || "unknown"
    "feishu://#{source.id}/#{tenant}"
  end

  defp event_actor(actor) do
    %{
      external_account_id: actor.id,
      display_name: actor.display,
      principal: nil
    }
  end

  defp actor_from_sender(sender, %Source{} = source),
    do: actor_from_ids(sender_ids(sender), source, profile_from_sender(sender))

  defp actor_from_ids(ids, %Source{} = source, profile \\ %{}) do
    ids = sender_ids(ids)

    case present_string(Map.get(ids, "open_id")) do
      open_id when is_binary(open_id) and open_id != "" ->
        {:ok, actor(open_id, ids, profile)}

      _value ->
        with {:ok, open_id} <- resolve_open_id(ids, source) do
          {:ok, actor(open_id, Map.put(ids, "open_id", open_id), profile)}
        end
    end
  end

  defp actor(open_id, ids, profile) do
    %{
      id: "feishu:" <> open_id,
      open_id: open_id,
      user_id: Map.get(ids, "user_id"),
      union_id: Map.get(ids, "union_id"),
      display: profile["display_name"] || profile["name"] || open_id,
      bot: false
    }
  end

  defp resolve_open_id(ids, %Source{} = source) do
    with :error <- resolve_open_id_by(ids, source, "user_id"),
         :error <- resolve_open_id_by(ids, source, "union_id") do
      {:error, Feishu.Error.payload(BullX.I18n.t("eventbus.feishu.errors.profile_unavailable"))}
    else
      {:ok, open_id} -> {:ok, open_id}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_open_id_by(ids, %Source{} = source, id_type) do
    case present_string(Map.get(ids, id_type)) do
      nil ->
        :error

      id ->
        case UserInfo.fetch_contact(source, id, id_type) do
          {:ok, userinfo} ->
            UserInfo.open_id(userinfo)

          {:error, error} ->
            {:error, Feishu.Error.map(error)}

          _other ->
            :error
        end
    end
  end

  defp sender_ids(%{"sender_id" => ids}) when is_map(ids), do: ids
  defp sender_ids(%{"operator_id" => ids}) when is_map(ids), do: ids
  defp sender_ids(map) when is_map(map), do: stringify_keys(map)
  defp sender_ids(_value), do: %{}

  defp profile_from_sender(sender) when is_map(sender) do
    ids = sender_ids(sender)

    %{}
    |> maybe_put("display_name", first_string(sender, ["name", "display_name", "sender_name"]))
    |> maybe_put("avatar_url", first_string(sender, ["avatar_url", "avatar"]))
    |> maybe_put("email", normalized_email(first_string(sender, ["email"])))
    |> maybe_put_phone(first_string(sender, ["mobile", "phone"]))
    |> maybe_put("open_id", ids["open_id"])
    |> maybe_put("union_id", ids["union_id"])
    |> maybe_put("user_id", ids["user_id"])
  end

  defp profile_from_card(%CardAction{} = action) do
    %{}
    |> maybe_put("open_id", action.open_id)
    |> maybe_put("user_id", action.user_id)
  end

  defp account_input(%Source{} = source, external_id, profile, env) do
    %{
      "adapter" => "feishu",
      "channel_id" => source.id,
      "external_id" => external_id,
      "profile" => profile,
      "metadata" =>
        %{
          "source" => "feishu_im",
          "tenant_key" => Map.get(env, :tenant_key),
          "chat_id" => Map.get(env, :chat_id),
          "chat_type" => Map.get(env, :chat_type)
        }
        |> reject_nil_values()
    }
  end

  defp context(env, actor, blocks, account_input) do
    %{
      event_id: env.event_id,
      event_type: env.event_type,
      scope_id: env.chat_id,
      chat_id: env.chat_id,
      chat_type: env.chat_type,
      message_id: env.message_id,
      actor: actor,
      content: blocks,
      account_input: account_input
    }
  end

  defp refs(env) do
    [
      %{
        kind: "feishu.message",
        id: env.message_id
      }
    ]
  end

  defp reply_channel(%Source{} = source, env) do
    %{
      adapter: "feishu",
      channel_id: source.id,
      scope_id: env.chat_id,
      scope_kind: channel_kind(env.chat_type),
      chat_type: env.chat_type,
      delivery_mode: "stream",
      thread_id: env.thread_id,
      reply_to_external_id: env.reply_to_external_id || env.message_id
    }
  end

  defp routing_facts(%Source{} = source, env, blocks, extra_facts) do
    %{
      "provider" => "feishu",
      "source_id" => source.id,
      "provider_event_type" => env.event_type,
      "chat_type" => env.chat_type,
      "content_kind" => first_content_kind(blocks),
      "im_listen_mode" => Atom.to_string(source.im_listen_mode)
    }
    |> reject_nil_values()
    |> Map.merge(extra_facts)
  end

  defp command_args_kind(args) when is_binary(args) do
    case String.trim(args) do
      "" -> "none"
      _args -> "text"
    end
  end

  defp raw_ref(env) do
    %{
      kind: "feishu.event",
      id: env.event_id,
      event_id: env.event_id,
      event_type: env.event_type,
      message_id: env.message_id,
      app_id: env.app_id,
      tenant_key: env.tenant_key
    }
    |> reject_nil_values()
  end

  defp event_time(%Event{created_at: %DateTime{} = datetime}), do: DateTime.to_iso8601(datetime)
  defp event_time(_event), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp reaction_emoji(raw_event) do
    reaction = Map.get(raw_event, "reaction") || raw_event

    Map.get(reaction, "emoji_type") || Map.get(reaction, "emoji") ||
      Map.get(reaction, "reaction_type")
  end

  defp action_id(%CardAction{} = action) do
    action
    |> action_id_candidates()
    |> Enum.find_value(&present_string/1)
    |> case do
      nil -> "submit"
      id -> id
    end
  end

  defp card_action_event_id(%CardAction{token: token}, _actor, _action_id)
       when is_binary(token) and token != "",
       do: token

  defp card_action_event_id(%CardAction{} = action, actor, action_id) do
    [
      "card_action",
      action.open_message_id || "unknown_message",
      action_id,
      actor.open_id || actor.user_id || "unknown_actor"
    ]
    |> Enum.join(":")
  end

  defp action_blocks(%CardAction{} = action, action_id) do
    values = action_values(action)

    block =
      %{
        "type" => "action",
        "text" => action_text(action_id, values),
        "action_id" => action_id
      }
      |> maybe_put("values", values)

    [block]
  end

  defp action_id_candidates(%CardAction{action: action} = card) when is_map(action) do
    values = action_values(card) || %{}

    [
      Map.get(values, "action_id"),
      Map.get(values, "bullx_action"),
      Map.get(action, "tag"),
      Map.get(action, "name")
    ]
  end

  defp action_id_candidates(_action), do: []

  defp action_text(_action_id, %{"bullx_action" => "clarify_answer"} = values) do
    case clarify_choice_text(values) do
      nil -> "clarification answer submitted"
      choice -> "Clarification answer: #{choice}"
    end
  end

  defp action_text(action_id, _values), do: "submitted action: #{action_id}"

  defp clarify_choice_text(%{"choice_value" => value} = values) do
    present_string(value) || values |> Map.delete("choice_value") |> clarify_choice_text()
  end

  defp clarify_choice_text(%{"choice_index" => index}), do: clarify_choice_index_text(index)
  defp clarify_choice_text(_values), do: nil

  defp clarify_choice_index_text(index) when is_integer(index) and index >= 0,
    do: "choice #{index + 1}"

  defp clarify_choice_index_text(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} when parsed >= 0 -> clarify_choice_index_text(parsed)
      _other -> nil
    end
  end

  defp clarify_choice_index_text(_index), do: nil

  defp action_values(%CardAction{action: action}) when is_map(action) do
    action
    |> first_value(["value", "form_value", "values"])
    |> sanitize_json_value()
  end

  defp action_values(_action), do: nil

  defp first_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp sanitize_json_value(%{} = map) do
    map
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(key) ->
        case sanitize_json_value(value) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end

      {_key, _value}, acc ->
        acc
    end)
    |> empty_to_nil()
  end

  defp sanitize_json_value(values) when is_list(values) do
    values
    |> Enum.map(&sanitize_json_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp sanitize_json_value(value) when is_binary(value) do
    value
    |> String.replace(<<0>>, "")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp sanitize_json_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: value

  defp sanitize_json_value(_value), do: nil

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

  defp first_content_kind([%{"type" => type} | _rest]), do: type
  defp first_content_kind([%{"kind" => kind} | _rest]), do: kind
  defp first_content_kind(_blocks), do: nil

  defp channel_kind("p2p"), do: "dm"
  defp channel_kind("group"), do: "group"
  defp channel_kind(nil), do: nil
  defp channel_kind(_chat_type), do: "group"

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end)
  end

  defp normalized_email(nil), do: nil
  defp normalized_email(email), do: email |> String.trim() |> String.downcase()

  defp maybe_put_phone(map, nil), do: map

  defp maybe_put_phone(map, phone) do
    phone
    |> phone_candidates()
    |> Enum.find_value(fn candidate ->
      case BullX.Ext.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        _other -> nil
      end
    end)
    |> case do
      nil -> map
      normalized -> Map.put(map, "phone", normalized)
    end
  end

  defp phone_candidates(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    case String.length(digits) == 11 and String.starts_with?(digits, "1") do
      true -> [trimmed, "+86" <> digits]
      false -> [trimmed]
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp present?(value), do: is_binary(value) and value != ""
  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_value), do: nil
end
