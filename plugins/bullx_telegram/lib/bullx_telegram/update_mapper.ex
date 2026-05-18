defmodule BullxTelegram.UpdateMapper do
  @moduledoc false

  alias BullxTelegram.{AttentionPolicy, CommandNormalizer, ContentMapper, Source}

  @spec map(term(), Source.t()) ::
          {:ok, map()} | {:direct_command, map()} | {:ignore, atom()} | {:error, map()}
  def map(%{} = update, %Source{} = source) do
    case update_message(update) do
      {:ok, provider_update_type, message} ->
        map_message(update, provider_update_type, message, source)

      :error ->
        {:ignore, :unsupported_update}
    end
  end

  def map(_update, _source), do: {:error, BullxTelegram.Error.payload("invalid Telegram update")}

  defp map_message(update, provider_update_type, message, %Source{} = source) do
    with {:ok, update_id} <- required_id(update, "update_id"),
         {:ok, message_id} <- required_id(message, "message_id"),
         {:ok, actor} <- actor(message),
         {:ok, blocks} <- ContentMapper.from_message(message),
         text <- ContentMapper.primary_text(blocks),
         command_result <- CommandNormalizer.parse(text, source.bot_username),
         {:attention, {:ok, attention_reason}} <-
           {:attention, AttentionPolicy.decide(message, source, command_result)} do
      context = context(update_id, provider_update_type, message, source, attention_reason)

      case command_result do
        {:direct, command} ->
          {:direct_command, Map.merge(command, direct_context(context, actor))}

        {:eventbus, command} ->
          mapped(update_id, message_id, source, message, actor, blocks, context, "bullx.command.invoked", command)

        _result ->
          mapped(update_id, message_id, source, message, actor, blocks, context, event_type(provider_update_type), %{})
      end
    else
      {:attention, {:ignore, reason}} -> {:ignore, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp mapped(update_id, message_id, source, message, actor, blocks, context, event_type, command) do
    {:ok,
     %{
       attrs: attrs(update_id, message_id, source, message, actor, blocks, context, event_type, command),
       account_input: account_input(source, actor, context),
       command?: event_type == "bullx.command.invoked"
     }}
  end

  defp update_message(%{"message" => message}) when is_map(message), do: {:ok, "message", message}
  defp update_message(%{"edited_message" => message}) when is_map(message), do: {:ok, "edited_message", message}
  defp update_message(_update), do: :error

  defp attrs(update_id, message_id, source, message, actor, blocks, context, event_type, command) do
    %{
      id: update_id,
      source: "telegram://#{source.id}/bot/#{source.bot_id || "unknown"}",
      type: event_type,
      time: event_time(message),
      subject: "Telegram message #{message_id}",
      data: %{
        content: command_content(blocks, command),
        channel: %{adapter: "telegram", id: source.id},
        scope: %{id: context.chat_id, thread_id: context.thread_id},
        actor: %{
          id: actor.id,
          display: actor.display,
          bot: actor.bot,
          principal_ref: nil,
          profile: actor.profile
        },
        refs: refs(update_id, message_id, context, actor),
        reply_channel: %{
          adapter: "telegram",
          channel_id: source.id,
          scope_id: context.chat_id,
          thread_id: context.thread_id,
          reply_to_external_id: message_id
        },
        routing_facts: routing_facts(source, context, blocks, command),
        raw_ref: %{"kind" => "telegram.update", "id" => update_id}
      }
    }
  end

  defp command_content(blocks, %{args: args}) when is_binary(args) and args != "" do
    [%{"kind" => "text", "body" => %{"text" => args}} | Enum.reject(blocks, &match?(%{"kind" => "text"}, &1))]
  end

  defp command_content(blocks, _command), do: blocks

  defp context(update_id, provider_update_type, message, %Source{} = source, attention_reason) do
    chat = Map.get(message, "chat") || %{}

    %{
      update_id: update_id,
      provider_update_type: provider_update_type,
      chat_id: stringify_id(Map.get(chat, "id")),
      chat_type: Map.get(chat, "type"),
      thread_id: stringify_id(Map.get(message, "message_thread_id")),
      attention_reason: attention_reason,
      connected_realm_ref: source.connected_realm_ref
    }
  end

  defp direct_context(context, actor) do
    %{
      event_id: context.update_id,
      chat_id: context.chat_id,
      chat_type: context.chat_type,
      thread_id: context.thread_id,
      actor: actor
    }
  end

  defp account_input(%Source{} = source, actor, context) do
    %{
      "adapter" => "telegram",
      "channel_id" => source.id,
      "external_id" => actor.id,
      "profile" => actor.profile,
      "metadata" =>
        %{
          "connected_realm_ref" => source.connected_realm_ref,
          "chat_id" => context.chat_id,
          "chat_type" => context.chat_type,
          "thread_id" => context.thread_id
        }
        |> reject_nil_values()
    }
  end

  defp actor(%{"from" => from}) when is_map(from) do
    case stringify_id(Map.get(from, "id")) do
      id when is_binary(id) and id != "" ->
        profile = profile(from, id)

        {:ok,
         %{
           id: "telegram:" <> id,
           display: Map.get(profile, "display_name"),
           bot: Map.get(from, "is_bot") == true,
           profile: profile
         }}

      _value ->
        {:error, BullxTelegram.Error.payload("Telegram actor is missing user id")}
    end
  end

  defp actor(_message), do: {:error, BullxTelegram.Error.payload("Telegram message is missing actor")}

  defp profile(from, id) do
    first = Map.get(from, "first_name")
    last = Map.get(from, "last_name")
    username = Map.get(from, "username")
    display = [first, last] |> Enum.filter(&present?/1) |> Enum.join(" ")

    %{}
    |> maybe_put("display_name", first_present([display, username, "telegram:" <> id]))
    |> maybe_put("username", username)
    |> maybe_put("first_name", first)
    |> maybe_put("last_name", last)
    |> maybe_put("language_code", Map.get(from, "language_code"))
    |> maybe_put("user_id", id)
  end

  defp routing_facts(source, context, blocks, command) do
    %{
      "provider_update_type" => context.provider_update_type,
      "chat_type" => context.chat_type,
      "content_kind" => first_content_kind(blocks),
      "attention_reason" => context.attention_reason,
      "connected_realm_ref" => source.connected_realm_ref
    }
    |> put_command_facts(command)
    |> reject_nil_values()
  end

  defp put_command_facts(facts, %{name: name} = command) do
    facts
    |> Map.put("command_name", name)
    |> Map.put("command_surface", command.surface)
    |> Map.put("command_args_kind", command.args_kind)
  end

  defp put_command_facts(facts, _command), do: facts

  defp refs(update_id, message_id, context, actor) do
    [
      %{"kind" => "telegram.update", "id" => update_id},
      %{"kind" => "telegram.message", "id" => message_id},
      %{"kind" => "telegram.chat", "id" => context.chat_id},
      maybe_ref("telegram.thread", context.thread_id),
      %{"kind" => "telegram.user", "id" => String.replace_prefix(actor.id, "telegram:", "")}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp event_type("edited_message"), do: "bullx.message.edited"
  defp event_type(_type), do: "bullx.message.created"

  defp required_id(map, key) do
    case stringify_id(Map.get(map, key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, BullxTelegram.Error.payload("Telegram update is missing #{key}")}
    end
  end

  defp event_time(%{"date" => unix}) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp event_time(_message), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp first_content_kind([%{"kind" => kind} | _rest]), do: kind
  defp first_content_kind(_blocks), do: nil
  defp maybe_ref(_kind, nil), do: nil
  defp maybe_ref(kind, id), do: %{"kind" => kind, "id" => id}
  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(value) when is_binary(value), do: value
  defp stringify_id(_value), do: nil
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp first_present(values), do: Enum.find(values, &present?/1)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
