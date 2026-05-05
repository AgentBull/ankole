defmodule BullXDiscord.EventMapper do
  @moduledoc """
  Normalizes Discord messages and interactions into Gateway inputs.
  """

  alias BullXGateway.Delivery.Content
  alias BullXGateway.Inputs.{Message, SlashCommand}
  alias BullXDiscord.{AttentionPolicy, Cache, Config, DirectCommand, Error}

  @type result ::
          {:ok, map(), Cache.t()}
          | {:direct_command, DirectCommand.command(), Cache.t()}
          | {:ignore, atom(), Cache.t()}
          | {:error, map(), Cache.t()}

  @spec map_message(term(), Config.t(), Cache.t()) :: result()
  def map_message(message, %Config{} = config, %Cache{} = cache) do
    case AttentionPolicy.message_attention(message, config, cache) do
      {:ok, reason, cache} -> do_map_message(message, config, cache, reason)
      {:ignore, reason, cache} -> {:ignore, reason, cache}
    end
  end

  @spec map_interaction(term(), Config.t(), Cache.t()) :: result()
  def map_interaction(interaction, %Config{} = config, %Cache{} = cache) do
    case AttentionPolicy.interaction_attention(interaction, config, cache) do
      {:ok, reason, cache} -> do_map_interaction(interaction, config, cache, reason)
      {:ignore, reason, cache} -> {:ignore, reason, cache}
    end
  end

  @spec update_scope(map(), String.t()) :: map()
  def update_scope(%{input: input, context: context} = mapped, scope_id) do
    reply_channel = Map.put(input.reply_channel, :scope_id, scope_id)
    input = %{input | scope_id: scope_id, reply_channel: reply_channel}
    context = %{context | scope_id: scope_id}
    %{mapped | input: input, context: context}
  end

  defp do_map_message(message, config, cache, reason) do
    with {:ok, actor} <- actor_from_user(author(message)),
         profile <- profile_from_user(author(message)),
         account_input <- account_input(config, actor.id, profile, message, "discord_gateway"),
         context <- message_context(config, message, actor, account_input, reason),
         {:ok, text} <- message_text(message, config, reason) do
      map_message_text(text, message, config, context, cache, reason)
    else
      {:error, error} -> {:error, error, cache}
    end
  end

  defp map_message_text(text, message, config, context, cache, reason) do
    case DirectCommand.parse(text) do
      {:ok, %{name: name} = parsed} when name in ["ping", "preauth", "web_auth"] ->
        {:direct_command, direct_message_command(parsed, message, config, context), cache}

      _other ->
        blocks = [%Content{kind: :text, body: %{"text" => text}}]

        {:ok,
         %{
           input: %Message{
             id: id_string(field(message, :id)),
             source: source(config),
             channel: config.channel,
             scope_id: context.scope_id,
             thread_id: nil,
             actor: gateway_actor(context.actor),
             event: gateway_event("message_create", message, context, reason),
             reply_channel: reply_channel(config, context.scope_id),
             reply_to_external_id: id_string(field(message, :id)),
             refs: refs(message, context),
             content: blocks
           },
           account_input: context.account_input,
           context: Map.put(context, :content, blocks),
           auto_thread?: auto_thread_candidate?(message, config, reason)
         }, cache}
    end
  end

  defp do_map_interaction(interaction, config, cache, reason) do
    with {:ok, actor} <- actor_from_user(interaction_user(interaction)),
         profile <- profile_from_user(interaction_user(interaction)),
         account_input <-
           account_input(config, actor.id, profile, interaction, "discord_interaction"),
         context <- interaction_context(config, interaction, actor, account_input, reason),
         name when is_binary(name) <- command_name(interaction) do
      map_interaction_command(name, interaction, config, context, cache, reason)
    else
      {:error, error} -> {:error, error, cache}
      _other -> {:ignore, :unsupported_interaction, cache}
    end
  end

  defp map_interaction_command(name, interaction, config, context, cache, _reason)
       when name in ["ping", "preauth", "web_auth"] do
    parsed = %{name: name, args: command_args(interaction)}
    {:direct_command, direct_interaction_command(parsed, interaction, config, context), cache}
  end

  defp map_interaction_command("ask", interaction, config, context, cache, reason) do
    prompt = command_option(interaction, "prompt") |> to_string() |> String.trim()

    case prompt do
      "" ->
        {:error, Error.payload("Discord /ask prompt is required", %{"field" => "prompt"}), cache}

      prompt ->
        blocks = [%Content{kind: :text, body: %{"text" => prompt}}]

        {:ok,
         %{
           input: %SlashCommand{
             id: id_string(field(interaction, :id)),
             source: source(config),
             channel: config.channel,
             scope_id: context.scope_id,
             thread_id: nil,
             actor: gateway_actor(context.actor),
             event: gateway_event("interaction_create", interaction, context, reason),
             reply_channel: reply_channel(config, context.scope_id),
             command_name: "ask",
             args: prompt,
             refs: refs(interaction, context),
             content: blocks
           },
           account_input: context.account_input,
           context: Map.put(context, :content, blocks),
           interaction: interaction,
           auto_thread?: auto_thread_candidate?(interaction, config, reason)
         }, cache}
    end
  end

  defp map_interaction_command(_name, _interaction, _config, _context, cache, _reason),
    do: {:ignore, :unsupported_interaction, cache}

  defp direct_message_command(parsed, message, config, context) do
    Map.merge(parsed, %{
      transport: :message,
      event_id: id_string(field(message, :id)),
      channel: config.channel,
      channel_id: config.channel_id,
      discord_channel_id: id_string(field(message, :channel_id)),
      guild_id: id_string(field(message, :guild_id)),
      message_id: id_string(field(message, :id)),
      actor: context.actor,
      account_input: context.account_input,
      source: source(config),
      dm?: is_nil(field(message, :guild_id))
    })
  end

  defp direct_interaction_command(parsed, interaction, config, context) do
    Map.merge(parsed, %{
      transport: :interaction,
      event_id: id_string(field(interaction, :id)),
      channel: config.channel,
      channel_id: config.channel_id,
      discord_channel_id: id_string(field(interaction, :channel_id)),
      guild_id: id_string(field(interaction, :guild_id)),
      message_id: nil,
      interaction: interaction,
      actor: context.actor,
      account_input: context.account_input,
      source: source(config),
      dm?: is_nil(field(interaction, :guild_id))
    })
  end

  defp message_text(message, config, _reason) do
    text =
      message
      |> text_content()
      |> strip_bot_mentions(config)
      |> String.trim()

    present_text(text)
  end

  defp present_text(""), do: {:error, Error.payload("Discord message content is empty")}
  defp present_text(text), do: {:ok, text}

  defp auto_thread_candidate?(message_or_interaction, config, reason) do
    config.auto_thread.enabled == true and reason in ["mention", "application_command"] and
      not is_nil(field(message_or_interaction, :guild_id)) and
      id_string(field(message_or_interaction, :channel_id)) not in config.auto_thread.no_thread_channel_ids
  end

  defp actor_from_user(nil), do: {:error, Error.payload("Discord user profile is unavailable")}

  defp actor_from_user(user) do
    case id_string(field(user, :id)) do
      nil ->
        {:error, Error.payload("Discord user profile is unavailable")}

      id ->
        {:ok,
         %{
           id: "discord:" <> id,
           user_id: id,
           display: display_name(user),
           bot: field(user, :bot) == true
         }}
    end
  end

  defp profile_from_user(user) do
    %{}
    |> maybe_put("display_name", display_name(user))
    |> maybe_put("username", field(user, :username))
    |> maybe_put("avatar_url", avatar_url(user))
    |> maybe_put("user_id", id_string(field(user, :id)))
  end

  defp account_input(config, external_id, profile, event, source) do
    %{
      adapter: :discord,
      channel_id: config.channel_id,
      external_id: external_id,
      profile: profile,
      metadata:
        %{
          "source" => source,
          "guild_id" => id_string(field(event, :guild_id)),
          "channel_id" => id_string(field(event, :channel_id))
        }
        |> reject_nil_values()
    }
  end

  defp message_context(config, message, actor, account_input, reason) do
    %{
      event_id: id_string(field(message, :id)),
      event_type: "message_create",
      scope_id: id_string(field(message, :channel_id)),
      discord_channel_id: id_string(field(message, :channel_id)),
      guild_id: id_string(field(message, :guild_id)),
      message_id: id_string(field(message, :id)),
      actor: actor,
      account_input: account_input,
      attention_reason: reason,
      channel: config.channel
    }
  end

  defp interaction_context(config, interaction, actor, account_input, reason) do
    %{
      event_id: id_string(field(interaction, :id)),
      event_type: "interaction_create",
      scope_id: id_string(field(interaction, :channel_id)),
      discord_channel_id: id_string(field(interaction, :channel_id)),
      guild_id: id_string(field(interaction, :guild_id)),
      message_id: nil,
      actor: actor,
      account_input: account_input,
      attention_reason: reason,
      channel: config.channel
    }
  end

  defp gateway_event(name, event, context, reason) do
    %{
      name: name,
      version: 1,
      data: %{
        "discord" =>
          %{
            "event_id" => context.event_id,
            "event_type" => context.event_type,
            "guild_id" => context.guild_id,
            "channel_id" => context.discord_channel_id,
            "message_id" => context.message_id,
            "attention_reason" => reason,
            "interaction_name" => command_name(event)
          }
          |> reject_nil_values()
      }
    }
  end

  defp refs(_event, context) do
    id = context.event_id || context.message_id || context.discord_channel_id || "unknown"

    [
      %{
        "kind" => "discord",
        "id" => id,
        "guild_id" => context.guild_id,
        "channel_id" => context.discord_channel_id,
        "message_id" => context.message_id
      }
      |> reject_nil_values()
    ]
  end

  defp reply_channel(config, scope_id) do
    %{adapter: :discord, channel_id: config.channel_id, scope_id: scope_id, thread_id: nil}
  end

  defp gateway_actor(actor), do: %{id: actor.id, display: actor.display, bot: actor.bot}
  defp source(%Config{channel_id: channel_id}), do: "bullx://gateway/discord/#{channel_id}"

  defp author(message), do: field(message, :author)

  defp interaction_user(interaction) do
    field(interaction, :user) || get_in_field(field(interaction, :member), [:user])
  end

  defp command_name(interaction), do: get_in_field(field(interaction, :data), [:name])

  defp command_args(interaction) do
    interaction
    |> field(:data)
    |> field(:options)
    |> case do
      options when is_list(options) ->
        options
        |> Enum.map(fn option -> "#{field(option, :name)}:#{field(option, :value)}" end)
        |> Enum.join(" ")

      _other ->
        ""
    end
  end

  defp command_option(interaction, name) do
    interaction
    |> field(:data)
    |> field(:options)
    |> case do
      options when is_list(options) ->
        Enum.find_value(options, fn option ->
          case field(option, :name) do
            ^name -> field(option, :value)
            _other -> nil
          end
        end)

      _other ->
        nil
    end
  end

  defp strip_bot_mentions(text, %Config{bot_user_id: bot_user_id}) when is_binary(bot_user_id) do
    text
    |> String.replace("<@#{bot_user_id}>", "")
    |> String.replace("<@!#{bot_user_id}>", "")
  end

  defp strip_bot_mentions(text, %Config{}), do: String.replace(text, ~r/<@!?\d+>/, "")

  defp text_content(message), do: to_string(field(message, :content) || "")

  defp display_name(user) do
    first_string([field(user, :global_name), field(user, :username), id_string(field(user, :id))])
  end

  defp avatar_url(user) do
    with id when is_binary(id) <- id_string(field(user, :id)),
         avatar when is_binary(avatar) and avatar != "" <- field(user, :avatar) do
      "https://cdn.discordapp.com/avatars/#{id}/#{avatar}.webp"
    else
      _other -> nil
    end
  end

  defp first_string(values) do
    Enum.find_value(values, fn
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end)
  end

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp get_in_field(nil, _keys), do: nil
  defp get_in_field(value, []), do: value
  defp get_in_field(value, [key | rest]), do: value |> field(key) |> get_in_field(rest)

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
