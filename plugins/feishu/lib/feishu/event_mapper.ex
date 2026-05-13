defmodule Feishu.EventMapper do
  @moduledoc false

  alias Feishu.{ContentMapper, DirectCommand, Source}
  alias FeishuOpenAPI.{CardAction, Event}

  @message_receive "im.message.receive_v1"
  @message_updated "im.message.updated_v1"
  @message_recalled "im.message.recalled_v1"
  @reaction_created "im.message.reaction.created_v1"
  @reaction_deleted "im.message.reaction.deleted_v1"

  @spec normalize_event(String.t(), Event.t(), Source.t()) :: {:ok, map()} | {:error, map()}
  def normalize_event(type, %Event{} = event, %Source{} = source) do
    case map_event(type, event, source) do
      {:ok, %{input: input}} -> {:ok, input}
      {:ignore, reason} -> {:error, Feishu.Error.ignored(reason)}
      {:direct_command, _command} -> {:error, Feishu.Error.ignored(:direct_command)}
      {:error, error} -> {:error, error}
    end
  end

  @spec normalize_card_action(CardAction.t(), Source.t()) :: {:ok, map()} | {:error, map()}
  def normalize_card_action(%CardAction{} = action, %Source{} = source) do
    case map_card_action(action, source) do
      {:ok, %{input: input}} -> {:ok, input}
      {:ignore, reason} -> {:error, Feishu.Error.ignored(reason)}
      {:error, error} -> {:error, error}
    end
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
         context <- context(env, actor, blocks, account_input) do
      maybe_message_or_command(text, env, actor, blocks, context, source)
    end
  end

  def map_event(@message_updated, %Event{} = event, %Source{} = source) do
    with {:ok, env} <- common_event_env(event, source),
         :ok <- reject_self_sent(env, source),
         {:ok, blocks} <- ContentMapper.from_message(env.message, source),
         {:ok, actor} <- actor_from_sender(env.sender, source),
         account_input <- account_input(source, actor.id, profile_from_sender(env.sender), env) do
      input =
        base_input(source, env, actor, blocks)
        |> Map.put("event", gateway_event("message_edited", @message_updated, event, env))
        |> put_in(["event", "data", "target_external_id"], env.message_id)

      {:ok,
       %{
         input: input,
         account_input: account_input,
         context: context(env, actor, blocks, account_input)
       }}
    end
  end

  def map_event(@message_recalled, %Event{} = event, %Source{} = source) do
    with {:ok, env} <- common_event_env(event, source),
         {:ok, actor} <- actor_from_sender(env.sender, source),
         account_input <- account_input(source, actor.id, profile_from_sender(env.sender), env) do
      input =
        source
        |> base_input(env, actor, [
          %{"kind" => "text", "body" => %{"text" => "[message recalled]"}}
        ])
        |> Map.put("event", gateway_event("message_recalled", @message_recalled, event, env))
        |> put_in(["event", "data", "target_external_id"], env.message_id)

      {:ok,
       %{
         input: input,
         account_input: account_input,
         context: context(env, actor, [], account_input)
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

      input =
        source
        |> base_input(env, actor, [%{"kind" => "text", "body" => %{"text" => ":#{emoji}:"}}])
        |> Map.put("event", gateway_event("reaction", type, event, env))
        |> put_in(["event", "data"], %{
          "target_external_id" => env.message_id,
          "emoji" => emoji,
          "action" => action
        })

      {:ok,
       %{
         input: input,
         account_input: account_input,
         context: context(env, actor, [], account_input)
       }}
    else
      nil -> {:error, Feishu.Error.payload("Feishu reaction event is missing emoji")}
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
         env <- card_env(action, source),
         account_input <- account_input(source, actor.id, profile_from_card(action), env) do
      action_id = action_id(action)

      input =
        source
        |> base_input(env, actor, [%{"kind" => "text", "body" => %{"text" => "[card action]"}}])
        |> Map.put("occurrence_key", occurrence_key(source, "card", env.event_id))
        |> Map.put("event", %{
          "type" => "action",
          "name" => "feishu.card.action",
          "version" => 1,
          "data" => %{
            "target_external_id" => action.open_message_id || "unknown",
            "action_id" => action_id,
            "values" => action_values(action)
          }
        })

      {:ok,
       %{
         input: input,
         account_input: account_input,
         context: context(env, actor, [], account_input)
       }}
    end
  end

  defp maybe_message_or_command(text, env, actor, blocks, context, source) do
    case DirectCommand.parse(text) do
      {:ok, %{name: name} = parsed} when name in ["ping", "preauth", "web_auth"] ->
        {:direct_command,
         Map.merge(parsed, %{
           event_id: env.event_id,
           channel_id: source.channel_id,
           chat_id: env.chat_id,
           chat_type: env.chat_type,
           thread_id: env.thread_id,
           message_id: env.message_id,
           actor: actor,
           account_input: context.account_input
         })}

      {:ok, %{name: name, args: args}} ->
        input =
          source
          |> base_input(env, actor, blocks)
          |> Map.put("event", gateway_event("slash_command", @message_receive, env.event, env))
          |> put_in(["event", "data"], %{"command_name" => name, "args" => args})

        {:ok, %{input: input, account_input: context.account_input, context: context}}

      :error ->
        input =
          source
          |> base_input(env, actor, blocks)
          |> Map.put("event", gateway_event("message", @message_receive, env.event, env))

        {:ok, %{input: input, account_input: context.account_input, context: context}}
    end
  end

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

  defp card_env(%CardAction{} = action, %Source{} = source) do
    %{
      raw_event: action.raw,
      event_id: action.token || action.open_message_id || "unknown",
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

  defp reject_self_sent(%{sender: sender}, %Source{} = source) do
    sender_type = Map.get(sender, "sender_type")
    ids = sender_ids(sender)

    case sender_type in ["bot", "app"] and present?(source.bot_open_id) and
           ids["open_id"] == source.bot_open_id do
      true -> {:ignore, :self_sent_bot_message}
      false -> :ok
    end
  end

  defp base_input(%Source{} = source, env, actor, blocks) do
    %{
      "adapter" => "feishu",
      "channel_id" => source.channel_id,
      "occurrence_key" => occurrence_key(source, "event", env.event_id),
      "time" => event_time(env.event),
      "content" => blocks,
      "event" => gateway_event("message", env.event_type, env.event, env),
      "actor" => gateway_actor(actor),
      "scope_id" => env.chat_id,
      "thread_id" => env.thread_id,
      "refs" => refs(env),
      "reply_channel" => reply_channel(source, env),
      "provenance" => provenance(env)
    }
  end

  defp gateway_event(type, provider_name, %Event{} = event, env) do
    %{
      "type" => type,
      "name" => "feishu." <> provider_name,
      "version" => 1,
      "data" =>
        %{
          "message_id" => env.message_id,
          "open_message_id" => env.open_message_id,
          "chat_id" => env.chat_id,
          "chat_type" => env.chat_type,
          "event_id" => event.id || env.event_id
        }
        |> reject_nil_values()
    }
  end

  defp gateway_actor(actor) do
    %{
      "id" => actor.id,
      "display" => actor.display,
      "bot" => actor.bot,
      "profile" =>
        %{
          "open_id" => actor.open_id,
          "union_id" => actor.union_id,
          "user_id" => actor.user_id
        }
        |> reject_nil_values()
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
      {:error, Feishu.Error.payload(BullX.I18n.t("gateway.feishu.errors.profile_unavailable"))}
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
        case FeishuOpenAPI.get(Source.client!(source), "/open-apis/contact/v3/users/:user_id",
               path_params: %{user_id: id},
               query: [user_id_type: id_type]
             ) do
          {:ok, %{"data" => %{"user" => %{"open_id" => open_id}}}}
          when is_binary(open_id) and open_id != "" ->
            {:ok, open_id}

          {:ok, %{"data" => %{"open_id" => open_id}}} when is_binary(open_id) and open_id != "" ->
            {:ok, open_id}

          {:error, error} ->
            {:error, Feishu.Error.map(error)}

          _other ->
            :error
        end
    end
  end

  defp sender_ids(%{"sender_id" => ids}) when is_map(ids), do: ids
  defp sender_ids(%{"operator_id" => ids}) when is_map(ids), do: ids
  defp sender_ids(map) when is_map(map), do: map
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
      "channel_id" => source.channel_id,
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
        "kind" => "feishu.message",
        "id" => env.message_id
      }
    ]
  end

  defp reply_channel(%Source{} = source, env) do
    %{
      "adapter" => "feishu",
      "channel_id" => source.channel_id,
      "scope_id" => env.chat_id,
      "thread_id" => env.thread_id,
      "reply_to_external_id" => env.reply_to_external_id || env.message_id
    }
  end

  defp provenance(env) do
    %{
      "event_id" => env.event_id,
      "event_type" => env.event_type,
      "app_id" => env.app_id,
      "tenant_key" => env.tenant_key
    }
    |> reject_nil_values()
  end

  defp occurrence_key(%Source{} = source, kind, id) do
    "feishu:#{source.channel_id}:#{kind}:#{id}"
  end

  defp event_time(%Event{created_at: %DateTime{} = datetime}), do: DateTime.to_iso8601(datetime)
  defp event_time(_event), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp reaction_emoji(raw_event) do
    reaction = Map.get(raw_event, "reaction") || raw_event

    Map.get(reaction, "emoji_type") || Map.get(reaction, "emoji") ||
      Map.get(reaction, "reaction_type")
  end

  defp action_id(%CardAction{action: %{"tag" => tag}}) when is_binary(tag), do: tag
  defp action_id(%CardAction{action: %{"name" => name}}) when is_binary(name), do: name

  defp action_id(%CardAction{action: %{"value" => %{"action_id" => id}}}) when is_binary(id),
    do: id

  defp action_id(_action), do: "submit"

  defp action_values(%CardAction{action: %{"value" => values}}) when is_map(values), do: values

  defp action_values(%CardAction{action: action}) when is_map(action),
    do: Map.get(action, "value", %{})

  defp action_values(_action), do: %{}

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
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

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp present?(value), do: is_binary(value) and value != ""
  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_value), do: nil
end
