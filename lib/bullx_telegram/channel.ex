defmodule BullXTelegram.Channel do
  @moduledoc false

  use GenServer
  require Logger

  alias BullXTelegram.{Cache, Commands, Config, DirectCommand, Error, Poller, UpdateMapper}

  defstruct [:channel, :config, :cache]

  def child_spec({channel, config}) do
    %{
      id: {__MODULE__, channel},
      start: {__MODULE__, :start_link, [{channel, config}]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link({channel, config}) do
    GenServer.start_link(__MODULE__, {channel, config}, name: via(channel))
  end

  def poller_child_spec({_channel, %Config{start_transport?: false}}), do: nil
  def poller_child_spec({_channel, %Config{transport: %{mode: "webhook"}}}), do: nil

  def poller_child_spec({channel, %Config{} = config}) do
    {Poller, {channel, config}}
  end

  def handle_update(%Config{} = config, update) do
    handle_update(config.channel, update)
  end

  def handle_update(channel, update) do
    GenServer.call(via(channel), {:update, update}, 30_000)
  end

  @impl true
  def init({channel, config}) do
    {:ok, cfg} = Config.normalize(channel, config)

    Logger.info("telegram channel start requested",
      channel: :telegram,
      channel_id: cfg.channel_id,
      transport: cfg.transport.mode
    )

    state = %__MODULE__{channel: channel, config: cfg, cache: Cache.new()}

    case cfg.start_transport? do
      true -> {:ok, state, {:continue, :startup}}
      false -> {:ok, state}
    end
  end

  @impl true
  def handle_continue(:startup, state) do
    state = verify_startup_bot(state)
    maybe_register_webhook(state)
    maybe_sync_commands(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:update, update}, _from, state) do
    {reply, state} = dispatch_update(update, state)
    {:reply, reply, state}
  end

  defp dispatch_update(update, state) do
    log_inbound(update, state)

    case UpdateMapper.map_update(update, state.config, state.cache) do
      {:ignore, reason, cache} ->
        log_result(:ignored, reason, update, state)
        {{:ok, %{status: :ignored, reason: reason}}, %{state | cache: cache}}

      {:direct_command, command, cache} ->
        state = %{state | cache: cache}
        handle_direct_command(command, update, state)

      {:ok, mapped, cache} ->
        state = %{state | cache: cache}
        publish_mapped(mapped, update, state)

      {:error, error, cache} ->
        log_result(:mapping_failed, error["kind"], update, state)
        {{:error, error}, %{state | cache: cache}}
    end
  end

  defp handle_direct_command(command, update, state) do
    case DirectCommand.handle(command, state.config, state.cache) do
      {:ok, result, cache} ->
        log_result(:direct_command_handled, command.name, update, state)
        {{:ok, result}, %{state | cache: cache}}

      {:error, error, cache} ->
        {{:error, error}, %{state | cache: cache}}
    end
  end

  defp publish_mapped(%{account_input: account_input, input: _input} = mapped, update, state) do
    case state.config.accounts_module.match_or_create_from_channel(account_input) do
      {:ok, _user, _binding} ->
        do_publish(mapped, update, state)

      {:error, :activation_required} ->
        reply_account_gate(
          mapped,
          update,
          state,
          activation_required_text(mapped),
          "activation_required"
        )

      {:error, :user_banned} ->
        reply_account_gate(
          mapped,
          update,
          state,
          BullX.I18n.t("gateway.telegram.auth.denied"),
          "denied"
        )

      {:error, reason} ->
        {{:error, Error.map(reason)}, state}
    end
  end

  defp do_publish(%{input: input}, update, state) do
    result = state.config.gateway_module.publish_inbound(input)
    log_result(elem(result, 0), result, update, state)
    {result, state}
  end

  defp reply_account_gate(mapped, update, state, text, command_name) do
    command = synthetic_reply_command(mapped, state, command_name)

    case DirectCommand.reply_text(command, state.config, state.cache, text, command_name) do
      {:ok, result, cache} ->
        log_result(command_name, result, update, state)
        {{:ok, result}, %{state | cache: cache}}

      {:error, error, cache} ->
        {{:error, error}, %{state | cache: cache}}
    end
  end

  defp activation_required_text(%{context: %{chat_type: "private"}}) do
    BullX.I18n.t("gateway.telegram.auth.activation_required")
  end

  defp activation_required_text(_mapped) do
    BullX.I18n.t("gateway.telegram.auth.direct_command_dm_only")
  end

  defp synthetic_reply_command(%{context: context}, state, command_name) do
    %{
      name: command_name,
      args: "",
      event_id: "#{context.event_id}:#{command_name}",
      channel: state.config.channel,
      channel_id: state.config.channel_id,
      chat_id: context.chat_id,
      chat_type: context.chat_type,
      thread_id: context.thread_id,
      message_id: context.message_id,
      actor: context.actor,
      account_input: context.account_input,
      source: "bullx://gateway/telegram/#{state.config.channel_id}"
    }
  end

  defp verify_startup_bot(%{config: config} = state) do
    case Config.request(config, "getMe") do
      {:ok, bot} ->
        Logger.info("telegram bot identity resolved",
          channel: :telegram,
          channel_id: config.channel_id,
          bot_id: id_string(field(bot, :id)),
          bot_username: field(bot, :username)
        )

        config = %{
          config
          | bot_id: id_string(field(bot, :id)),
            bot_username: field(bot, :username) || config.bot_username
        }

        %{state | config: config}

      {:error, error} ->
        Logger.warning("telegram bot identity failed",
          channel: :telegram,
          channel_id: config.channel_id,
          error: inspect(Error.map(error))
        )

        state
    end
  end

  defp maybe_register_webhook(%{
         config: %Config{transport: %{mode: "webhook", set_webhook: true}} = config
       }) do
    with :ok <- Config.validate_webhook_url(config),
         {:ok, result} <-
           Config.request(config, "setWebhook",
             url: Config.webhook_url(config),
             secret_token: config.transport.secret_token,
             allowed_updates: {:json, ["message", "edited_message"]}
           ) do
      Logger.info("telegram webhook registered",
        channel: :telegram,
        channel_id: config.channel_id,
        result: inspect(result)
      )
    else
      {:error, error} ->
        Logger.warning("telegram webhook registration failed",
          channel: :telegram,
          channel_id: config.channel_id,
          error: inspect(error)
        )
    end
  end

  defp maybe_register_webhook(_state), do: :ok

  defp maybe_sync_commands(%{config: %Config{transport: %{mode: "polling"}}}), do: :ok

  defp maybe_sync_commands(%{config: config}) do
    case Commands.sync(config) do
      {:ok, result} ->
        Logger.info("telegram command menu sync result",
          channel: :telegram,
          channel_id: config.channel_id,
          status: inspect(result)
        )

      {:error, error} ->
        Logger.warning("telegram command menu sync failed",
          channel: :telegram,
          channel_id: config.channel_id,
          error: inspect(error)
        )
    end
  end

  defp via(channel),
    do: {:via, Registry, {BullXGateway.AdapterSupervisor.Registry, {__MODULE__, channel}}}

  defp log_inbound(update, state) do
    message = field(update, :message) || field(update, :edited_message) || %{}

    Logger.info("telegram inbound update received",
      channel: :telegram,
      channel_id: state.config.channel_id,
      update_id: field(update, :update_id),
      message_id: field(message, :message_id),
      chat_id: message |> field(:chat) |> field(:id),
      thread_id: field(message, :message_thread_id),
      actor_id: message |> field(:from) |> field(:id)
    )
  end

  defp log_result(status, detail, update, state) do
    Logger.info("telegram inbound result",
      channel: :telegram,
      channel_id: state.config.channel_id,
      update_id: field(update, :update_id),
      status: status,
      detail: inspect(detail)
    )
  end

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
