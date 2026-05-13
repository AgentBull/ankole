defmodule BullxTelegram.UpdateMapper do
  @moduledoc """
  Normalizes Telegram updates into Gateway inbound inputs or adapter-local
  direct commands.

  Numeric Telegram ids (`update_id`, `message_id`, `chat_id`,
  `message_thread_id`, `user_id`) are stringified before they enter the
  Gateway carrier so the JSON neutral contract holds for ids beyond 53 bits.
  """

  alias BullxTelegram.{AttentionPolicy, ContentMapper, DirectCommand, Error, Source}

  @type mapped ::
          {:ok, map()}
          | {:direct_command, map()}
          | {:ignore, atom()}
          | {:error, map()}

  @spec map_update(map(), Source.t()) :: mapped()
  def map_update(update, %Source{} = source) when is_map(update) do
    case message_from_update(update) do
      {:ok, message, event_type} -> map_message(update, message, event_type, source)
      :error -> {:ignore, :unsupported_update}
    end
  end

  def map_update(_update, %Source{}), do: {:ignore, :unsupported_update}

  defp map_message(update, message, event_type, %Source{} = source) do
    case AttentionPolicy.message_attention(message, source) do
      {:ok, reason} -> do_map_message(update, message, event_type, source, reason)
      {:ignore, reason} -> {:ignore, reason}
    end
  end

  defp do_map_message(update, message, event_type, %Source{} = source, reason) do
    with {:ok, actor} <- actor_from_user(field(message, :from)),
         env <- message_env(update, message, event_type, actor, reason, source),
         account_input <- account_input(source, env),
         {:ok, blocks} <- ContentMapper.inbound_blocks(message) do
      map_message_blocks(env, blocks, source, account_input)
    end
  end

  defp map_message_blocks(env, blocks, %Source{} = source, account_input) do
    text = ContentMapper.primary_text(blocks)

    case DirectCommand.parse(text, source) do
      {:ok, parsed} ->
        {:direct_command, direct_command(parsed, env, source, account_input)}

      _other ->
        case slash_command_input(text, env, blocks, source, account_input) do
          nil -> {:ok, mapped_message(env, blocks, source, account_input)}
          mapped -> {:ok, mapped}
        end
    end
  end

  defp slash_command_input(nil, _env, _blocks, _source, _account_input), do: nil

  defp slash_command_input(text, env, blocks, %Source{} = source, account_input) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "/") do
      case String.split(String.trim_leading(trimmed, "/"), ~r/\s+/, parts: 2) do
        [raw_name | rest] when raw_name != "" ->
          {name, _bot} = strip_bot_username(raw_name)
          args = Enum.join(rest, " ")

          input =
            base_input(env, blocks, source)
            |> Map.put("event", gateway_event("slash_command", env, %{
              "command_name" => name,
              "args" => args
            }))

          %{input: input, account_input: account_input, context: context(env, blocks)}

        _other ->
          nil
      end
    end
  end

  defp mapped_message(env, blocks, %Source{} = source, account_input) do
    input =
      base_input(env, blocks, source)
      |> Map.put("event", gateway_event("message", env, %{}))

    %{input: input, account_input: account_input, context: context(env, blocks)}
  end

  defp direct_command(parsed, env, %Source{} = source, account_input) do
    Map.merge(parsed, %{
      event_id: env.event_id,
      channel_id: source.channel_id,
      chat_id: env.chat_id,
      chat_type: env.chat_type,
      thread_id: env.thread_id,
      message_id: env.message_id,
      actor: env.actor,
      account_input: account_input
    })
  end

  defp message_env(update, message, event_type, actor, reason, %Source{} = source) do
    update_id = stringify_id(field(update, :update_id))
    message_id = stringify_id(field(message, :message_id))
    chat = field(message, :chat) || %{}
    chat_id = stringify_id(field(chat, :id))
    chat_type = field(chat, :type)
    thread_id = stringify_id(field(message, :message_thread_id))
    date = field(message, :date)

    %{
      raw_update: update,
      raw_message: message,
      event_id: occurrence_event_id(source, update_id),
      occurrence_key: occurrence_key(source, update_id),
      event_type: event_type,
      update_id: update_id,
      message_id: message_id,
      chat_id: chat_id,
      chat_type: chat_type,
      thread_id: thread_id,
      attention_reason: reason,
      actor: actor,
      date: date,
      time: event_time(date)
    }
  end

  defp base_input(env, blocks, %Source{} = source) do
    %{
      "adapter" => "telegram",
      "channel_id" => source.channel_id,
      "occurrence_key" => env.occurrence_key,
      "time" => env.time,
      "content" => blocks,
      "actor" => gateway_actor(env.actor),
      "scope_id" => env.chat_id,
      "thread_id" => env.thread_id,
      "refs" => refs(env),
      "reply_channel" => reply_channel(env, source),
      "provenance" => provenance(env)
    }
  end

  defp gateway_event(type, env, extra_data) do
    base = %{
      "update_id" => env.update_id,
      "message_id" => env.message_id,
      "chat_id" => env.chat_id,
      "chat_type" => env.chat_type,
      "thread_id" => env.thread_id,
      "attention_reason" => env.attention_reason,
      "update_type" => env.event_type,
      "date" => env.date
    }

    data =
      base
      |> Map.merge(extra_data)
      |> reject_nil_values()

    name =
      case env.event_type do
        "edited_message" -> "telegram.edited_message"
        _other -> "telegram.message"
      end

    %{
      "type" => type,
      "name" => name,
      "version" => 1,
      "data" => data
    }
  end

  defp gateway_actor(actor) do
    %{
      "id" => actor.id,
      "display" => actor.display,
      "bot" => actor.bot,
      "profile" => actor.profile,
      "metadata" => actor.metadata
    }
  end

  defp refs(env) do
    [
      ref("telegram.update", env.update_id),
      ref("telegram.message", env.message_id),
      ref("telegram.chat", env.chat_id),
      ref("telegram.thread", env.thread_id),
      ref("telegram.user", actor_user_id(env.actor))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp ref(_kind, nil), do: nil
  defp ref(kind, id), do: %{"kind" => kind, "id" => to_string(id)}

  defp reply_channel(env, %Source{} = source) do
    %{
      "adapter" => "telegram",
      "channel_id" => source.channel_id,
      "scope_id" => env.chat_id,
      "thread_id" => env.thread_id,
      "reply_to_external_id" => env.message_id
    }
    |> reject_nil_values()
  end

  defp provenance(env) do
    %{
      "update_id" => env.update_id,
      "update_type" => env.event_type
    }
    |> reject_nil_values()
  end

  defp context(env, blocks) do
    %{
      event_id: env.event_id,
      event_type: env.event_type,
      scope_id: env.chat_id,
      chat_id: env.chat_id,
      chat_type: env.chat_type,
      message_id: env.message_id,
      thread_id: env.thread_id,
      actor: env.actor,
      content: blocks
    }
  end

  defp account_input(%Source{} = source, env) do
    %{
      "adapter" => "telegram",
      "channel_id" => source.channel_id,
      "external_id" => env.actor.id,
      "profile" => env.actor.profile,
      "metadata" =>
        %{
          "source" => "telegram_im",
          "chat_id" => env.chat_id,
          "chat_type" => env.chat_type,
          "thread_id" => env.thread_id
        }
        |> reject_nil_values()
    }
  end

  defp actor_from_user(nil),
    do: {:error, Error.payload("Telegram user profile is unavailable")}

  defp actor_from_user(user) when is_map(user) do
    case stringify_id(field(user, :id)) do
      nil ->
        {:error, Error.payload("Telegram user profile is unavailable")}

      id ->
        profile = profile_from_user(user)

        {:ok,
         %{
           id: "telegram:" <> id,
           user_id: id,
           display: display_name(user),
           bot: field(user, :is_bot) == true,
           profile: profile,
           metadata: %{
             "language_code" => field(user, :language_code),
             "is_premium" => field(user, :is_premium)
           }
           |> reject_nil_values()
         }}
    end
  end

  defp profile_from_user(user) when is_map(user) do
    %{
      "display_name" => display_name(user),
      "username" => field(user, :username),
      "first_name" => field(user, :first_name),
      "last_name" => field(user, :last_name),
      "language_code" => field(user, :language_code),
      "user_id" => stringify_id(field(user, :id))
    }
    |> reject_nil_values()
  end

  defp profile_from_user(_user), do: %{}

  defp display_name(user) do
    first = field(user, :first_name)
    last = field(user, :last_name)
    username = field(user, :username)

    name =
      [first, last]
      |> Enum.filter(&present?/1)
      |> Enum.join(" ")
      |> String.trim()

    cond do
      name != "" -> name
      present?(username) -> username
      true -> "telegram:" <> to_string(field(user, :id))
    end
  end

  defp actor_user_id(%{user_id: id}) when is_binary(id), do: id
  defp actor_user_id(_actor), do: nil

  defp message_from_update(update) do
    cond do
      is_map(field(update, :message)) -> {:ok, field(update, :message), "message"}
      is_map(field(update, :edited_message)) -> {:ok, field(update, :edited_message), "edited_message"}
      true -> :error
    end
  end

  defp occurrence_key(%Source{channel_id: cid}, update_id) when is_binary(update_id) do
    "telegram:#{cid}:update:#{update_id}"
  end

  defp occurrence_key(%Source{channel_id: cid}, _update_id) do
    "telegram:#{cid}:update:unknown"
  end

  defp occurrence_event_id(_source, update_id) when is_binary(update_id), do: update_id
  defp occurrence_event_id(_source, _update_id), do: "unknown"

  defp event_time(date) when is_integer(date) and date > 0 do
    case DateTime.from_unix(date) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _other -> now_iso8601()
    end
  end

  defp event_time(_date), do: now_iso8601()

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp strip_bot_username(raw_name) do
    case String.split(raw_name, "@", parts: 2) do
      [name] -> {String.downcase(name), nil}
      [name, bot] -> {String.downcase(name), bot}
    end
  end

  defp stringify_id(nil), do: nil
  defp stringify_id(value) when is_binary(value) and value != "", do: value
  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(_value), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp reject_nil_values(map),
    do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
