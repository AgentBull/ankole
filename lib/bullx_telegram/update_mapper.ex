defmodule BullXTelegram.UpdateMapper do
  @moduledoc """
  Normalizes Telegram updates into Gateway inputs or adapter-local commands.
  """

  alias BullXGateway.Inputs.{Message, SlashCommand}
  alias BullXTelegram.{AttentionPolicy, Cache, Config, ContentMapper, DirectCommand, Error}

  @type result ::
          {:ok, map(), Cache.t()}
          | {:direct_command, DirectCommand.command(), Cache.t()}
          | {:ignore, atom(), Cache.t()}
          | {:error, map(), Cache.t()}

  @spec map_update(map(), Config.t(), Cache.t()) :: result()
  def map_update(update, %Config{} = config, %Cache{} = cache) when is_map(update) do
    case message_from_update(update) do
      {:ok, message, event_type} -> map_message(update, message, event_type, config, cache)
      :error -> {:ignore, :unsupported_update, cache}
    end
  end

  def map_update(_update, %Config{}, %Cache{} = cache), do: {:ignore, :unsupported_update, cache}

  defp map_message(update, message, event_type, config, cache) do
    case AttentionPolicy.message_attention(message, config) do
      {:ok, reason} -> do_map_message(update, message, event_type, config, cache, reason)
      {:ignore, reason} -> {:ignore, reason, cache}
    end
  end

  defp do_map_message(update, message, event_type, config, cache, reason) do
    with {:ok, actor} <- actor_from_user(field(message, :from)),
         profile <- profile_from_user(field(message, :from)),
         account_input <- account_input(config, actor.id, profile, message),
         context <-
           message_context(update, message, config, actor, account_input, event_type, reason),
         {:ok, blocks} <- ContentMapper.inbound_blocks(message) do
      map_message_blocks(update, message, config, context, blocks, cache, reason)
    else
      {:error, error} -> {:error, error, cache}
    end
  end

  defp map_message_blocks(update, message, config, context, blocks, cache, reason) do
    text = primary_text(blocks)

    case DirectCommand.parse(text, config) do
      {:ok, %{name: name} = parsed} when name in ["ping", "preauth", "web_auth"] ->
        {:direct_command, direct_command(parsed, update, message, config, context), cache}

      {:ok, %{name: "ask", args: args}} ->
        map_ask_command(args, update, message, config, context, cache, reason)

      _other ->
        {:ok, mapped_message(update, message, config, context, blocks, reason), cache}
    end
  end

  defp map_ask_command(args, update, message, config, context, cache, reason) do
    prompt = String.trim(args)

    case prompt do
      "" ->
        parsed = %{name: "ask_prompt_required", args: ""}
        {:direct_command, direct_command(parsed, update, message, config, context), cache}

      prompt ->
        {:ok, mapped_ask(update, message, config, context, prompt, reason), cache}
    end
  end

  defp mapped_message(update, message, config, context, blocks, reason) do
    %{
      input: %Message{
        id: input_id(update, message),
        source: source(config),
        channel: config.channel,
        scope_id: context.scope_id,
        thread_id: context.thread_id,
        actor: gateway_actor(context.actor),
        event: gateway_event(context.event_type, update, message, context, reason),
        reply_channel: reply_channel(config, context),
        reply_to_external_id: context.message_id,
        refs: refs(update, message, context),
        content: blocks
      },
      account_input: context.account_input,
      context: Map.put(context, :content, blocks)
    }
  end

  defp mapped_ask(update, message, config, context, prompt, reason) do
    blocks = [%BullXGateway.Delivery.Content{kind: :text, body: %{"text" => prompt}}]

    %{
      input: %SlashCommand{
        id: input_id(update, message, "ask"),
        source: source(config),
        channel: config.channel,
        scope_id: context.scope_id,
        thread_id: context.thread_id,
        actor: gateway_actor(context.actor),
        event: gateway_event(context.event_type, update, message, context, reason),
        reply_channel: reply_channel(config, context),
        command_name: "ask",
        args: prompt,
        reply_to_external_id: context.message_id,
        refs: refs(update, message, context),
        content: blocks
      },
      account_input: context.account_input,
      context: Map.put(context, :content, blocks)
    }
  end

  defp direct_command(parsed, update, message, config, context) do
    Map.merge(parsed, %{
      event_id: input_id(update, message, parsed.name),
      channel: config.channel,
      channel_id: config.channel_id,
      chat_id: context.scope_id,
      chat_type: context.chat_type,
      thread_id: context.thread_id,
      message_id: context.message_id,
      actor: context.actor,
      account_input: context.account_input,
      source: source(config)
    })
  end

  defp message_from_update(update) do
    cond do
      is_map(field(update, :message)) ->
        {:ok, field(update, :message), "message"}

      is_map(field(update, :edited_message)) ->
        {:ok, field(update, :edited_message), "edited_message"}

      true ->
        :error
    end
  end

  defp actor_from_user(nil), do: {:error, Error.payload("Telegram user profile is unavailable")}

  defp actor_from_user(user) do
    case id_string(field(user, :id)) do
      nil ->
        {:error, Error.payload("Telegram user profile is unavailable")}

      id ->
        {:ok,
         %{
           id: "telegram:" <> id,
           user_id: id,
           display: display_name(user),
           bot: field(user, :is_bot) == true
         }}
    end
  end

  defp profile_from_user(user) do
    %{}
    |> maybe_put("display_name", display_name(user))
    |> maybe_put("username", field(user, :username))
    |> maybe_put("first_name", field(user, :first_name))
    |> maybe_put("last_name", field(user, :last_name))
    |> maybe_put("language_code", field(user, :language_code))
    |> maybe_put("user_id", id_string(field(user, :id)))
  end

  defp account_input(config, external_id, profile, message) do
    %{
      adapter: :telegram,
      channel_id: config.channel_id,
      external_id: external_id,
      profile: profile,
      metadata:
        %{
          "chat_id" => chat_id(message),
          "chat_type" => chat_type(message),
          "thread_id" => thread_id(message)
        }
        |> reject_nil_values()
    }
  end

  defp message_context(update, message, config, actor, account_input, event_type, reason) do
    %{
      event_id: input_id(update, message),
      event_type: event_type,
      update_id: update_id(update),
      scope_id: chat_id(message),
      chat_id: chat_id(message),
      chat_type: chat_type(message),
      thread_id: thread_id(message),
      message_id: message_id(message),
      actor: actor,
      account_input: account_input,
      attention_reason: reason,
      channel: config.channel
    }
  end

  defp gateway_actor(actor) do
    %{id: actor.id, display: actor.display, bot: actor.bot}
  end

  defp gateway_event(event_type, update, message, context, reason) do
    %{
      name: "telegram.#{event_type}",
      version: 1,
      data: %{
        "telegram" => %{
          "update_id" => context.update_id,
          "message_id" => context.message_id,
          "chat_id" => context.chat_id,
          "chat_type" => context.chat_type,
          "thread_id" => context.thread_id,
          "attention_reason" => reason,
          "update_type" => event_type,
          "date" => field(message, :date),
          "raw_update_keys" => Map.keys(update)
        }
      }
    }
  end

  defp reply_channel(config, context) do
    %{
      adapter: :telegram,
      channel_id: config.channel_id,
      scope_id: context.scope_id,
      thread_id: context.thread_id
    }
  end

  defp refs(update, message, context) do
    [
      ref("telegram.update", update_id(update)),
      ref("telegram.message", message_id(message)),
      ref("telegram.chat", context.chat_id),
      ref("telegram.thread", context.thread_id),
      ref("telegram.user", context.actor.user_id)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp ref(_kind, nil), do: nil
  defp ref(kind, id), do: %{kind: kind, id: id}

  defp primary_text([%BullXGateway.Delivery.Content{kind: :text, body: %{"text" => text}} | _]),
    do: text

  defp primary_text([_ | rest]), do: primary_text(rest)
  defp primary_text([]), do: ""

  defp input_id(update, message), do: input_id(update, message, nil)

  defp input_id(update, message, nil), do: "#{update_id(update)}:#{message_id(message)}"

  defp input_id(update, message, suffix),
    do: "#{update_id(update)}:#{message_id(message)}:#{suffix}"

  defp source(config), do: "bullx://gateway/telegram/#{config.channel_id}"

  defp chat_id(message), do: message |> field(:chat) |> field(:id) |> id_string()
  defp chat_type(message), do: message |> field(:chat) |> field(:type)
  defp thread_id(message), do: message |> field(:message_thread_id) |> id_string()
  defp message_id(message), do: message |> field(:message_id) |> id_string()
  defp update_id(update), do: update |> field(:update_id) |> id_string()

  defp display_name(user) do
    [field(user, :first_name), field(user, :last_name)]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> first_string([field(user, :username), id_string(field(user, :id))])
      name -> name
    end
  end

  defp first_string([value | _rest]) when is_binary(value) and value != "", do: value
  defp first_string([_value | rest]), do: first_string(rest)
  defp first_string([]), do: "Telegram user"

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
