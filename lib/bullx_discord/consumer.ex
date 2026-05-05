defmodule BullXDiscord.Consumer do
  @moduledoc false

  @behaviour Nostrum.Consumer

  require Logger

  alias BullXDiscord.{
    ApplicationCommands,
    Config,
    DirectCommand,
    Error,
    EventMapper,
    ThreadOwnership
  }

  @impl true
  def handle_event(event) do
    bot_name = Nostrum.Bot.get_bot_name()
    BullXDiscord.Channel.handle_event_by_bot_name(bot_name, event)
  end

  def handle_event({:READY, ready, _ws_state}, state) do
    config = maybe_put_ready_bot_user(state.config, ready)

    case ApplicationCommands.sync(config) do
      {:ok, result} ->
        Logger.info("discord application commands sync result",
          channel: :discord,
          channel_id: config.channel_id,
          status: inspect(result)
        )

      {:error, error} ->
        Logger.warning("discord application commands sync failed",
          channel: :discord,
          channel_id: config.channel_id,
          error: inspect(error)
        )
    end

    {{:ok, %{status: :ready}}, %{state | config: config}}
  end

  def handle_event({:MESSAGE_CREATE, message, _ws_state}, state) do
    case EventMapper.map_message(message, state.config, state.cache) do
      {:ignore, reason, cache} ->
        {{:ok, %{status: :ignored, reason: reason}}, %{state | cache: cache}}

      {:direct_command, command, cache} ->
        state = %{state | cache: cache}
        handle_direct_command(command, state)

      {:ok, mapped, cache} ->
        state = %{state | cache: cache}
        publish_mapped(mapped, state)

      {:error, error, cache} ->
        {{:error, error}, %{state | cache: cache}}
    end
  end

  def handle_event({:INTERACTION_CREATE, interaction, _ws_state}, state) do
    case EventMapper.map_interaction(interaction, state.config, state.cache) do
      {:ignore, reason, cache} ->
        {{:ok, %{status: :ignored, reason: reason}}, %{state | cache: cache}}

      {:direct_command, command, cache} ->
        state = %{state | cache: cache}
        handle_direct_command(command, state)

      {:ok, mapped, cache} ->
        state = %{state | cache: cache}
        publish_mapped(mapped, state)

      {:error, error, cache} ->
        {{:error, error}, %{state | cache: cache}}
    end
  end

  def handle_event(_event, state), do: {{:ok, %{status: :ignored}}, state}

  defp handle_direct_command(command, state) do
    case DirectCommand.handle(command, state.config, state.cache) do
      {:ok, result, cache} ->
        Logger.info("discord direct command handled",
          channel: :discord,
          channel_id: state.config.channel_id,
          command_name: command.name
        )

        {{:ok, result}, %{state | cache: cache}}

      {:error, error, cache} ->
        {{:error, error}, %{state | cache: cache}}
    end
  end

  defp publish_mapped(%{account_input: account_input, input: _input} = mapped, state) do
    case state.config.accounts_module.match_or_create_from_channel(account_input) do
      {:ok, _user, _binding} ->
        publish_after_account_gate(mapped, state)

      {:error, :activation_required} ->
        reply_account_gate(mapped, state, activation_required_text(mapped), "activation_required")

      {:error, :user_banned} ->
        reply_account_gate(mapped, state, BullX.I18n.t("gateway.discord.auth.denied"), "denied")

      {:error, reason} ->
        {{:error, Error.map(reason)}, state}
    end
  end

  defp publish_after_account_gate(mapped, state) do
    with {:ok, mapped, state} <- maybe_auto_thread(mapped, state),
         :ok <- maybe_ack_ask(mapped, state.config),
         result <- state.config.gateway_module.publish_inbound(mapped.input) do
      {result, state}
    else
      {:error, error, state} -> {{:error, error}, state}
    end
  end

  defp maybe_auto_thread(%{auto_thread?: true, context: context} = mapped, state) do
    with {:ok, true} <-
           ThreadOwnership.guild_text_channel?(context.discord_channel_id, state.config),
         {:ok, thread} <- create_thread(mapped, state.config) do
      thread_id = id_string(field(thread, :id))
      cache = ThreadOwnership.mark_owned(state.cache, state.config, thread_id)
      {:ok, EventMapper.update_scope(mapped, thread_id), %{state | cache: cache}}
    else
      {:ok, false} ->
        {:ok, mapped, state}

      {:error, error} ->
        reply_thread_error(mapped, state, error)
    end
  end

  defp maybe_auto_thread(mapped, state), do: {:ok, mapped, state}

  defp create_thread(%{context: %{message_id: message_id} = context}, config)
       when is_binary(message_id) do
    Config.with_bot(config, fn ->
      config.thread_api.create_with_message(
        snowflake(context.discord_channel_id),
        snowflake(message_id),
        thread_options(context, config)
      )
    end)
    |> case do
      {:ok, thread} -> {:ok, thread}
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp create_thread(%{context: context}, config) do
    Config.with_bot(config, fn ->
      config.thread_api.create(
        snowflake(context.discord_channel_id),
        thread_options(context, config)
      )
    end)
    |> case do
      {:ok, thread} -> {:ok, thread}
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp thread_options(context, config) do
    name =
      context
      |> Map.get(:content, [])
      |> primary_text()
      |> thread_name()

    %{
      name: name,
      auto_archive_duration: config.auto_thread.auto_archive_duration_minutes
    }
  end

  defp primary_text([%BullXGateway.Delivery.Content{kind: :text, body: %{"text" => text}} | _]),
    do: text

  defp primary_text([_ | rest]), do: primary_text(rest)
  defp primary_text([]), do: "BullX"

  defp thread_name(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "BullX"
      value -> String.slice(value, 0, 80)
    end
  end

  defp maybe_ack_ask(%{interaction: interaction}, config) do
    response = %{
      type: 4,
      data: %{
        content: BullX.I18n.t("gateway.discord.ask.accepted"),
        flags: 64,
        allowed_mentions: BullXDiscord.Delivery.allowed_mentions()
      }
    }

    Config.with_bot(config, fn ->
      config.interaction_api.create_response(interaction, response)
    end)
    |> case do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp maybe_ack_ask(_mapped, _config), do: :ok

  defp reply_account_gate(mapped, state, text, command_name) do
    command = synthetic_reply_command(mapped, state, command_name)
    handle_direct_reply(command, state, text, command_name)
  end

  defp reply_thread_error(mapped, state, error) do
    command = synthetic_reply_command(mapped, state, "thread_create_failed")
    text = BullX.I18n.t("gateway.discord.errors.thread_create_failed")

    case DirectCommand.reply_text(
           command,
           state.config,
           state.cache,
           text,
           "thread_create_failed"
         ) do
      {:ok, _result, cache} -> {:error, error, %{state | cache: cache}}
      {:error, reply_error, cache} -> {:error, reply_error, %{state | cache: cache}}
    end
  end

  defp handle_direct_reply(command, state, text, command_name) do
    case DirectCommand.reply_text(command, state.config, state.cache, text, command_name) do
      {:ok, result, cache} -> {{:ok, result}, %{state | cache: cache}}
      {:error, error, cache} -> {{:error, error}, %{state | cache: cache}}
    end
  end

  defp activation_required_text(%{context: %{guild_id: nil}}) do
    BullX.I18n.t("gateway.discord.auth.activation_required")
  end

  defp activation_required_text(_mapped) do
    BullX.I18n.t("gateway.discord.auth.direct_command_dm_only")
  end

  defp synthetic_reply_command(%{context: context} = mapped, state, command_name) do
    %{
      name: command_name,
      args: "",
      event_id: "#{context.event_id}:#{command_name}",
      channel: state.config.channel,
      channel_id: state.config.channel_id,
      discord_channel_id: context.discord_channel_id,
      guild_id: context.guild_id,
      message_id: context.message_id,
      actor: context.actor,
      account_input: context.account_input,
      source: "bullx://gateway/discord/#{state.config.channel_id}",
      transport: if(Map.has_key?(mapped, :interaction), do: :interaction, else: :message),
      interaction: Map.get(mapped, :interaction),
      dm?: is_nil(context.guild_id)
    }
  end

  defp maybe_put_ready_bot_user(config, ready) do
    case ready |> field(:user) |> field(:id) |> id_string() do
      nil -> config
      bot_user_id -> %{config | bot_user_id: bot_user_id}
    end
  end

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp snowflake(value) when is_integer(value), do: value

  defp snowflake(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp snowflake(value), do: value

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
