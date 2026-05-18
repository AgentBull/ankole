defmodule Discord.EventMapper do
  @moduledoc false

  alias Discord.{AttentionPolicy, CommandNormalizer, ContentMapper, Source}

  @spec map(term(), Source.t()) ::
          {:ok, map()} | {:direct_command, map()} | {:ignore, atom()} | {:error, map()}
  def map({event_type, payload}, %Source{} = source), do: map_event(event_type, payload, source)
  def map(%{"t" => event_type, "d" => payload}, %Source{} = source), do: map_event(event_type, payload, source)
  def map(%{"event_type" => event_type, "payload" => payload}, %Source{} = source), do: map_event(event_type, payload, source)
  def map(%{} = payload, %Source{} = source), do: map_event(Map.get(payload, "type", "message_create"), payload, source)
  def map(_payload, _source), do: {:error, Discord.Error.payload("invalid Discord payload")}

  defp map_event(event_type, payload, %Source{} = source) when event_type in ["MESSAGE_CREATE", :MESSAGE_CREATE, "message_create"] do
    map_message("message_create", payload, source, :im_message)
  end

  defp map_event(event_type, payload, %Source{} = source) when event_type in ["MESSAGE_UPDATE", :MESSAGE_UPDATE, "message_update"] do
    case Map.get(payload, "edited_timestamp") do
      value when is_binary(value) and value != "" ->
        map_message("message_update", payload, source, "bullx.message.edited")

      _value ->
        {:ignore, :non_user_edit}
    end
  end

  defp map_event(event_type, payload, %Source{} = source) when event_type in ["INTERACTION_CREATE", :INTERACTION_CREATE, "interaction_create"] do
    map_interaction(payload, source)
  end

  defp map_event(_event_type, _payload, _source), do: {:ignore, :unsupported_event}

  defp map_message(provider_event_type, payload, %Source{} = source, default_type) do
    with {:ok, message_id} <- required_id(payload, "id"),
         {:ok, actor} <- actor_from_author(Map.get(payload, "author")),
         {:ok, blocks} <- ContentMapper.from_message(payload, source),
         text <- ContentMapper.primary_text(blocks),
         command_result <- CommandNormalizer.parse_text(text),
         {:attention, attention} when elem(attention, 0) in [:ok, :ambient] <-
           {:attention, AttentionPolicy.decide(payload, source, command_result)} do
      {_decision, attention_reason} = attention
      context = context(provider_event_type, payload, source, attention_reason)
      resolved_type = resolve_event_type(default_type, attention)

      case command_result do
        {:direct, command} ->
          {:direct_command, Map.merge(command, direct_context(context, actor))}

        {:eventbus, command} ->
          mapped(message_id, source, actor, blocks, context, "bullx.command.invoked", command)

        _result ->
          mapped(event_id(resolved_type, message_id, payload), source, actor, blocks, context, resolved_type, %{})
      end
    else
      {:attention, {:ignore, reason}} -> {:ignore, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_event_type(:im_message, {:ambient, _reason}), do: "bullx.im.message.ambient"
  defp resolve_event_type(:im_message, _attention), do: "bullx.im.message.addressed"
  defp resolve_event_type(event_type, _attention), do: event_type

  defp map_interaction(payload, %Source{} = source) do
    with {:ok, interaction_id} <- required_id(payload, "id"),
         {:ok, actor} <- actor_from_interaction(payload),
         command_result <- CommandNormalizer.parse_interaction(payload),
         {:attention, {:ok, attention_reason}} <-
           {:attention, AttentionPolicy.decide(payload, source, command_result)} do
      context = context("interaction_create", payload, source, attention_reason)
      blocks = interaction_blocks(payload, command_result)

      case command_result do
        {:direct, command} ->
          {:direct_command, Map.merge(command, direct_context(context, actor))}

        {:eventbus, command} ->
          mapped(interaction_id, source, actor, blocks, context, "bullx.command.invoked", command)

        {:ignore, reason} ->
          {:ignore, reason}
      end
    else
      {:attention, {:ignore, reason}} -> {:ignore, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp mapped(event_id, source, actor, blocks, context, event_type, command) do
    {:ok,
     %{
       attrs: attrs(event_id, source, actor, blocks, context, event_type, command),
       account_input: account_input(source, actor, context),
       command?: event_type == "bullx.command.invoked"
     }}
  end

  defp attrs(event_id, source, actor, blocks, context, event_type, command) do
    %{
      id: event_id,
      source: "discord://#{source.id}/application/#{source.application_id}",
      type: event_type,
      time: context.time,
      subject: "Discord #{context.provider_event_type} #{event_id}",
      data: %{
        content: command_content(blocks, command),
        channel: %{adapter: "discord", id: source.id},
        scope: %{id: context.channel_id, thread_id: nil},
        actor: %{
          id: actor.id,
          display: actor.display,
          bot: actor.bot,
          principal_ref: nil,
          profile: actor.profile
        },
        refs: refs(event_id, context, actor),
        reply_channel: %{
          adapter: "discord",
          channel_id: source.id,
          scope_id: context.channel_id,
          thread_id: nil,
          reply_to_external_id: context.message_id
        },
        routing_facts: routing_facts(source, context, blocks, command),
        raw_ref: %{"kind" => raw_ref_kind(context.provider_event_type), "id" => event_id}
      }
    }
  end

  defp command_content(blocks, %{args: args}) when is_binary(args) and args != "" do
    [%{"kind" => "text", "body" => %{"text" => args}} | Enum.reject(blocks, &match?(%{"kind" => "text"}, &1))]
  end

  defp command_content(blocks, _command), do: blocks

  defp context(provider_event_type, payload, %Source{} = source, attention_reason) do
    %{
      provider_event_type: provider_event_type,
      channel_id: stringify_id(Map.get(payload, "channel_id")),
      guild_id: stringify_id(Map.get(payload, "guild_id")),
      message_id: stringify_id(Map.get(payload, "id")),
      time: Map.get(payload, "timestamp") || Map.get(payload, "edited_timestamp") || DateTime.utc_now() |> DateTime.to_iso8601(),
      attention_reason: attention_reason,
      connected_realm_ref: source.connected_realm_ref
    }
  end

  defp direct_context(context, actor) do
    %{
      event_id: context.message_id,
      channel_id: context.channel_id,
      guild_id: context.guild_id,
      actor: actor
    }
  end

  defp account_input(source, actor, context) do
    %{
      "adapter" => "discord",
      "channel_id" => source.id,
      "external_id" => actor.id,
      "profile" => actor.profile,
      "metadata" =>
        %{
          "connected_realm_ref" => source.connected_realm_ref,
          "guild_id" => context.guild_id,
          "discord_channel_id" => context.channel_id
        }
        |> reject_nil_values()
    }
  end

  defp actor_from_author(%{} = author) do
    case stringify_id(Map.get(author, "id")) do
      id when is_binary(id) and id != "" ->
        profile = profile(author, id)
        {:ok, %{id: "discord:" <> id, display: Map.get(profile, "display_name"), bot: Map.get(author, "bot") == true, profile: profile}}

      _value ->
        {:error, Discord.Error.payload("Discord author is missing user id")}
    end
  end

  defp actor_from_author(_author), do: {:error, Discord.Error.payload("Discord message is missing author")}

  defp actor_from_interaction(payload) do
    user = get_in(payload, ["member", "user"]) || Map.get(payload, "user")
    actor_from_author(user)
  end

  defp profile(author, id) do
    username = Map.get(author, "username")
    global_name = Map.get(author, "global_name")

    %{}
    |> maybe_put("display_name", first_present([global_name, username, "discord:" <> id]))
    |> maybe_put("global_name", global_name)
    |> maybe_put("username", username)
    |> maybe_put("avatar_url", avatar_url(author, id))
    |> maybe_put("locale", Map.get(author, "locale"))
    |> maybe_put("user_id", id)
  end

  defp interaction_blocks(_payload, {:eventbus, %{name: "ask", args: args}}) when is_binary(args) and args != "" do
    [%{"kind" => "text", "body" => %{"text" => args}}]
  end

  defp interaction_blocks(_payload, {:eventbus, %{name: name}}), do: [%{"kind" => "text", "body" => %{"text" => "/" <> name}}]
  defp interaction_blocks(_payload, _command), do: [%{"kind" => "text", "body" => %{"text" => "/command"}}]

  defp routing_facts(source, context, blocks, command) do
    %{
      "provider_event_type" => context.provider_event_type,
      "guild_id" => context.guild_id,
      "discord_channel_id" => context.channel_id,
      "content_kind" => first_content_kind(blocks),
      "attention_reason" => context.attention_reason,
      "im_listen_mode" => Atom.to_string(source.im_listen_mode),
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
    |> maybe_put("provider_command_id", Map.get(command, :provider_command_id))
  end

  defp put_command_facts(facts, _command), do: facts

  defp refs(event_id, context, actor) do
    [
      %{"kind" => raw_ref_kind(context.provider_event_type), "id" => event_id},
      maybe_ref("discord.channel", context.channel_id),
      maybe_ref("discord.guild", context.guild_id),
      %{"kind" => "discord.user", "id" => String.replace_prefix(actor.id, "discord:", "")}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp event_id("bullx.message.edited", message_id, payload), do: "edit:#{message_id}:#{Map.get(payload, "edited_timestamp")}"
  defp event_id(_type, message_id, _payload), do: message_id
  defp required_id(map, key), do: required_id_value(Map.get(map, key), key)

  defp required_id_value(value, key) do
    case stringify_id(value) do
      nil -> {:error, Discord.Error.payload("Discord payload is missing #{key}")}
      "" -> {:error, Discord.Error.payload("Discord payload is missing #{key}")}
      id -> {:ok, id}
    end
  end
  defp raw_ref_kind("interaction_create"), do: "discord.interaction"
  defp raw_ref_kind(_provider_event_type), do: "discord.message"
  defp first_content_kind([%{"kind" => kind} | _rest]), do: kind
  defp first_content_kind(_blocks), do: nil
  defp maybe_ref(_kind, nil), do: nil
  defp maybe_ref(kind, id), do: %{"kind" => kind, "id" => id}
  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(value) when is_binary(value), do: value
  defp stringify_id(_value), do: nil
  defp first_present(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))
  defp avatar_url(%{"avatar" => avatar}, id) when is_binary(avatar) and avatar != "", do: "https://cdn.discordapp.com/avatars/#{id}/#{avatar}.png"
  defp avatar_url(_author, _id), do: nil
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
