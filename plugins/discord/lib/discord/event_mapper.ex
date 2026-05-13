defmodule Discord.EventMapper do
  @moduledoc """
  Normalizes Discord Gateway events into Gateway inbound inputs and
  adapter-local direct commands.

  Supported events in v1:

  - `MESSAGE_CREATE` → `message` or `slash_command` (or intercepted direct
    command).
  - `MESSAGE_UPDATE` (user edits with `edited_timestamp`) → `message_edited`.
  - `INTERACTION_CREATE` (application command, type 2) → direct command for
    `ping/preauth/web_auth`; `slash_command` for `ask`.

  All Discord snowflake ids are stringified before they enter the Gateway
  carrier so the JSON neutral contract holds for 64-bit ids.
  """

  alias Discord.{AttentionPolicy, ContentMapper, DirectCommand, Error, Source}

  @type mapped ::
          {:ok, map()}
          | {:direct_command, map()}
          | {:ignore, atom()}
          | {:error, map()}

  @spec map_event(map(), String.t() | atom(), Source.t()) :: mapped()
  def map_event(payload, event_type, %Source{} = source)
      when is_map(payload) and is_binary(event_type) do
    do_map_event(payload, event_type, source)
  end

  def map_event(payload, event_type, %Source{} = source) when is_atom(event_type) do
    map_event(payload, Atom.to_string(event_type), source)
  end

  @doc """
  Variant used by `BullX.Gateway.Adapter.normalize_inbound/3`, which receives
  a single payload without the Nostrum event tag. The payload is expected to
  carry `"__event_type__"` (set by `Discord.Channel` when wrapping the
  payload) or `"event_type"` set by an upstream HTTP transport. Defaults to
  `"message_create"`.
  """
  @spec map_event(map(), Source.t()) :: mapped()
  def map_event(payload, %Source{} = source) when is_map(payload) do
    event_type =
      Map.get(payload, "__event_type__") || Map.get(payload, "event_type") || "message_create"

    map_event(payload, to_string(event_type), source)
  end

  def map_event(_payload, _source), do: {:ignore, :unsupported_event}

  defp do_map_event(payload, "message_create", %Source{} = source) do
    cond do
      bot_author?(payload, source) -> {:ignore, :bot_author}
      webhook?(payload) -> {:ignore, :webhook_author}
      anonymous?(payload) -> {:ignore, :anonymous_sender}
      true -> map_message(payload, "message_create", source)
    end
  end

  defp do_map_event(payload, "message_update", %Source{} = source) do
    cond do
      not is_user_edit?(payload) -> {:ignore, :non_user_edit}
      bot_author?(payload, source) -> {:ignore, :bot_author}
      webhook?(payload) -> {:ignore, :webhook_author}
      anonymous?(payload) -> {:ignore, :anonymous_sender}
      true -> map_message(payload, "message_update", source)
    end
  end

  defp do_map_event(payload, "interaction_create", %Source{} = source) do
    case interaction_type(payload) do
      2 -> map_application_command(payload, source)
      _other -> {:ignore, :unsupported_interaction}
    end
  end

  defp do_map_event(_payload, _event_type, _source), do: {:ignore, :unsupported_event}

  defp map_message(message, event_type, %Source{} = source) do
    case AttentionPolicy.message_attention(message, source) do
      {:ignore, reason} ->
        {:ignore, reason}

      {:ok, attention_reason} ->
        with {:ok, actor} <- actor_from_user(field(message, :author), source, message),
             {:ok, blocks, text} <- ContentMapper.inbound_blocks(message, source) do
          context = message_context(source, message, event_type, actor, attention_reason)
          account_input = account_input(source, actor, context, "discord_gateway")

          case event_type == "message_create" and detect_direct_command(text) do
            {:ok, parsed} ->
              {:direct_command,
               build_direct_command(parsed, message, source, context, account_input,
                 transport: :message
               )}

            _other ->
              build_message_input(
                event_type,
                source,
                blocks,
                context,
                account_input,
                attention_reason,
                text
              )
          end
        end
    end
  end

  defp map_application_command(interaction, %Source{} = source) do
    case AttentionPolicy.interaction_attention(interaction, source) do
      {:ignore, reason} ->
        {:ignore, reason}

      {:ok, attention_reason} ->
        with {:ok, actor} <- actor_from_user(interaction_user(interaction), source, interaction) do
          name = command_name(interaction)
          context = interaction_context(source, interaction, actor, attention_reason)
          account_input = account_input(source, actor, context, "discord_interaction")

          cond do
            name in ["ping", "preauth", "web_auth"] ->
              parsed = %{name: name, args: command_args(interaction)}

              {:direct_command,
               build_direct_command(parsed, interaction, source, context, account_input,
                 transport: :interaction,
                 interaction: interaction
               )}

            name == "ask" ->
              map_ask(interaction, source, actor, context, account_input, attention_reason)

            true ->
              {:ignore, :unsupported_interaction}
          end
        end
    end
  end

  defp map_ask(interaction, %Source{} = source, _actor, context, account_input, attention_reason) do
    prompt =
      interaction
      |> command_option("prompt")
      |> to_string()
      |> String.trim()

    case prompt do
      "" ->
        {:error, Error.payload("Discord /ask prompt is required", %{"field" => "prompt"})}

      prompt ->
        blocks = [%{"kind" => "text", "body" => %{"text" => prompt}}]

        ext_data = %{
          "command_name" => "ask",
          "args" => prompt
        }

        input = build_input(source, context, attention_reason, blocks, "slash_command", ext_data)

        auto_thread? =
          in_guild?(context) and source.auto_thread["enabled"] == true and
            not no_thread_channel?(context, source)

        {:ok,
         %{
           input: input,
           account_input: account_input,
           context: Map.put(context, :content, blocks),
           interaction: interaction,
           auto_thread?: auto_thread?
         }}
    end
  end

  defp build_message_input(
         event_type,
         %Source{} = source,
         blocks,
         context,
         account_input,
         attention_reason,
         text
       ) do
    {gateway_type, ext_data} =
      cond do
        event_type == "message_update" ->
          {"message_edited", %{"target_external_id" => context.message_id}}

        is_binary(text) and String.starts_with?(String.trim(text), "/") ->
          {"slash_command", slash_command_extras(text)}

        true ->
          {"message", %{}}
      end

    input = build_input(source, context, attention_reason, blocks, gateway_type, ext_data)

    auto_thread? =
      attention_reason in ["mention", "application_command"] and
        in_guild?(context) and
        source.auto_thread["enabled"] == true and
        not no_thread_channel?(context, source) and
        event_type == "message_create"

    {:ok,
     %{
       input: input,
       account_input: account_input,
       context: Map.put(context, :content, blocks),
       interaction: nil,
       auto_thread?: auto_thread?
     }}
  end

  defp build_input(
         %Source{} = source,
         context,
         attention_reason,
         blocks,
         gateway_type,
         ext_data
       ) do
    %{
      "adapter" => "discord",
      "channel_id" => source.channel_id,
      "occurrence_key" => occurrence_key(source, context),
      "time" => now_iso8601(),
      "content" => blocks,
      "actor" => actor_payload(context.actor),
      "scope_id" => context.scope_id,
      "thread_id" => nil,
      "refs" => refs(context),
      "reply_channel" => reply_channel(context, source),
      "event" => event_payload(gateway_type, context, attention_reason, ext_data),
      "provenance" => provenance(context, source)
    }
  end

  defp build_direct_command(parsed, payload, %Source{} = source, context, account_input, opts) do
    transport = Keyword.fetch!(opts, :transport)
    interaction = Keyword.get(opts, :interaction)

    Map.merge(parsed, %{
      transport: transport,
      event_id: context.event_id,
      channel_id: source.channel_id,
      scope_id: context.scope_id,
      discord_channel_id: context.discord_channel_id,
      guild_id: context.guild_id,
      message_id: context.message_id,
      actor: context.actor,
      account_input: account_input,
      interaction: interaction,
      dm?: is_nil(context.guild_id),
      raw_payload: payload
    })
  end

  defp detect_direct_command(text) do
    case DirectCommand.parse(text) do
      {:ok, parsed} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp slash_command_extras(text) do
    trimmed = text |> to_string() |> String.trim()

    case String.split(String.trim_leading(trimmed, "/"), ~r/\s+/, parts: 2) do
      [name | rest] when name != "" ->
        %{"command_name" => String.downcase(name), "args" => Enum.join(rest, " ")}

      _other ->
        %{}
    end
  end

  defp message_context(%Source{} = _source, message, event_type, actor, attention_reason) do
    discord_channel_id = id_string(field(message, :channel_id))
    guild_id = id_string(field(message, :guild_id))
    message_id = id_string(field(message, :id))
    edited_timestamp = field(message, :edited_timestamp)

    %{
      event_id: message_id || "unknown",
      event_type: event_type,
      scope_id: discord_channel_id,
      discord_channel_id: discord_channel_id,
      thread_channel_id: nil,
      guild_id: guild_id,
      message_id: message_id,
      interaction_id: nil,
      edited_timestamp: edited_timestamp,
      actor: actor,
      attention_reason: attention_reason
    }
  end

  defp interaction_context(%Source{} = _source, interaction, actor, attention_reason) do
    interaction_id = id_string(field(interaction, :id))
    discord_channel_id = id_string(field(interaction, :channel_id))
    guild_id = id_string(field(interaction, :guild_id))

    %{
      event_id: interaction_id || "unknown",
      event_type: "interaction_create",
      scope_id: discord_channel_id,
      discord_channel_id: discord_channel_id,
      thread_channel_id: nil,
      guild_id: guild_id,
      message_id: nil,
      interaction_id: interaction_id,
      edited_timestamp: nil,
      actor: actor,
      attention_reason: attention_reason
    }
  end

  defp occurrence_key(%Source{channel_id: cid}, %{
         event_type: "message_update",
         message_id: message_id,
         scope_id: scope_id,
         edited_timestamp: edited_timestamp
       })
       when is_binary(message_id) do
    "discord:#{cid}:edit:#{message_id}:#{edited_timestamp || scope_id || "unknown"}"
  end

  defp occurrence_key(%Source{channel_id: cid}, %{event_type: "interaction_create", event_id: id}) do
    "discord:#{cid}:interaction:#{id}"
  end

  defp occurrence_key(%Source{channel_id: cid}, %{event_id: id}) do
    "discord:#{cid}:message:#{id}"
  end

  defp event_payload(gateway_type, context, attention_reason, ext_data) do
    data =
      %{
        "guild_id" => context.guild_id,
        "discord_channel_id" => context.discord_channel_id,
        "message_id" => context.message_id,
        "interaction_id" => context.interaction_id,
        "attention_reason" => attention_reason,
        "event_type" => context.event_type,
        "edited_timestamp" => context.edited_timestamp
      }
      |> Map.merge(ext_data)
      |> reject_nil_values()

    name = event_name(context.event_type)

    %{
      "type" => gateway_type,
      "name" => name,
      "version" => 1,
      "data" => data
    }
  end

  defp event_name("message_create"), do: "discord.message_create"
  defp event_name("message_update"), do: "discord.message_update"
  defp event_name("interaction_create"), do: "discord.application_command"
  defp event_name(_other), do: "discord.unknown"

  defp refs(context) do
    [
      ref("discord.message", context.message_id),
      ref("discord.interaction", context.interaction_id),
      ref("discord.channel", context.discord_channel_id),
      ref("discord.guild", context.guild_id),
      ref("discord.user", actor_user_id(context.actor))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp ref(_kind, nil), do: nil
  defp ref(kind, id), do: %{"kind" => kind, "id" => to_string(id)}

  defp reply_channel(context, %Source{} = source) do
    %{
      "adapter" => "discord",
      "channel_id" => source.channel_id,
      "scope_id" => context.scope_id,
      "thread_id" => nil,
      "reply_to_external_id" => context.message_id
    }
    |> reject_nil_values()
  end

  defp provenance(context, %Source{} = source) do
    %{
      "event_id" => context.event_id,
      "event_type" => context.event_type,
      "application_id" => source.application_id
    }
    |> reject_nil_values()
  end

  defp account_input(%Source{} = source, actor, context, source_label) do
    %{
      "adapter" => "discord",
      "channel_id" => source.channel_id,
      "external_id" => actor.id,
      "profile" => actor.profile,
      "metadata" =>
        %{
          "source" => source_label,
          "guild_id" => context.guild_id,
          "discord_channel_id" => context.discord_channel_id
        }
        |> reject_nil_values()
    }
  end

  defp actor_payload(actor) do
    %{
      "id" => actor.id,
      "display" => actor.display,
      "bot" => actor.bot,
      "profile" => actor.profile,
      "metadata" => actor.metadata
    }
  end

  defp actor_user_id(%{user_id: id}) when is_binary(id), do: id
  defp actor_user_id(_actor), do: nil

  defp actor_from_user(nil, _source, _payload),
    do: {:error, Error.payload("Discord user profile is unavailable")}

  defp actor_from_user(user, _source, payload) when is_map(user) do
    case id_string(field(user, :id)) do
      nil ->
        {:error, Error.payload("Discord user profile is unavailable")}

      id ->
        profile = profile_from_user(user)
        guild_id = id_string(field(payload, :guild_id))

        {:ok,
         %{
           id: "discord:" <> id,
           user_id: id,
           display: display_name(user),
           bot: field(user, :bot) == true,
           profile: profile,
           metadata: %{"guild_id" => guild_id} |> reject_nil_values()
         }}
    end
  end

  defp profile_from_user(user) when is_map(user) do
    %{
      "display_name" => display_name(user),
      "global_name" => present(field(user, :global_name)),
      "username" => present(field(user, :username)),
      "avatar_url" => avatar_url(user),
      "user_id" => id_string(field(user, :id))
    }
    |> reject_nil_values()
  end

  defp profile_from_user(_user), do: %{}

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

  defp interaction_user(interaction) do
    field(interaction, :user) || get_in_field(field(interaction, :member), [:user])
  end

  defp command_name(interaction) do
    case get_in_field(field(interaction, :data), [:name]) do
      value when is_binary(value) and value != "" -> String.downcase(value)
      _other -> nil
    end
  end

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

  defp interaction_type(interaction) do
    case field(interaction, :type) do
      type when is_integer(type) -> type
      _other -> nil
    end
  end

  defp bot_author?(message, %Source{bot_user_id: bot_user_id}) do
    author = field(message, :author)

    cond do
      field(author, :bot) != true -> false
      is_binary(bot_user_id) and id_string(field(author, :id)) == bot_user_id -> true
      true -> false
    end
  end

  defp webhook?(message) do
    case field(message, :webhook_id) do
      value when is_binary(value) and value != "" -> true
      _other -> false
    end
  end

  defp anonymous?(message), do: is_nil(field(message, :author))

  defp is_user_edit?(message) do
    case field(message, :edited_timestamp) do
      value when is_binary(value) and value != "" -> true
      _other -> false
    end
  end

  defp in_guild?(%{guild_id: nil}), do: false
  defp in_guild?(%{guild_id: _value}), do: true

  defp no_thread_channel?(%{discord_channel_id: channel_id}, %Source{
         auto_thread: %{"no_thread_channel_ids" => list}
       }) do
    channel_id in list
  end

  defp first_string(values) do
    Enum.find_value(values, fn
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end)
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp get_in_field(nil, _keys), do: nil
  defp get_in_field(value, []), do: value
  defp get_in_field(value, [key | rest]), do: value |> field(key) |> get_in_field(rest)

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value) and value != "", do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(_value), do: nil

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp reject_nil_values(map),
    do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
