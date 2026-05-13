defmodule Discord.Channel do
  @moduledoc """
  Source-local runtime boundary for one configured Discord source.

  Holds the normalized config, awaits the Nostrum `:READY` event for bot
  identity resolution, runs application command sync, and dispatches inbound
  Discord events through `Discord.EventMapper`, the Principal account gate,
  optional auto-threading, and `BullX.Gateway.publish/2`.
  """

  use GenServer

  require Logger

  alias Discord.{
    ApplicationCommands,
    AskCommand,
    DirectCommand,
    Error,
    EventMapper,
    Source,
    ThreadOwnership
  }

  defstruct [:source, :bot_user_id, ready?: false]

  @type via :: {:via, Registry, {Discord.Registry, term()}}

  @registry Discord.Registry

  @spec child_spec({BullX.Gateway.SourceConfig.t(), Source.t()}) :: Supervisor.child_spec()
  def child_spec({_source_config, %Source{} = source}) do
    %{
      id: {__MODULE__, source.adapter, source.channel_id},
      start: {__MODULE__, :start_link, [source]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(Source.t()) :: GenServer.on_start()
  def start_link(%Source{} = source) do
    GenServer.start_link(__MODULE__, source, name: via(source))
  end

  @spec via(Source.t() | String.t() | atom()) :: via()
  def via(%Source{channel_id: channel_id}), do: via(channel_id)
  def via(channel_id) when is_binary(channel_id), do: {:via, Registry, {@registry, channel_id}}
  def via(bot_name) when is_atom(bot_name), do: {:via, Registry, {@registry, {:bot, bot_name}}}

  @spec handle_event(Source.t() | via() | String.t(), term(), timeout()) :: term()
  def handle_event(target, event, timeout \\ 30_000)

  def handle_event(%Source{} = source, event, timeout) do
    GenServer.call(via(source), {:event, event}, timeout)
  end

  def handle_event({:via, _registry, _key} = via, event, timeout) do
    GenServer.call(via, {:event, event}, timeout)
  end

  def handle_event(channel_id, event, timeout) when is_binary(channel_id) do
    GenServer.call(via(channel_id), {:event, event}, timeout)
  end

  @doc """
  Dispatches a Nostrum event to the channel registered for the bot whose
  process dictionary set its bot name. Used by `Discord.Consumer` to route
  events from `Nostrum.Bot.get_bot_name/0` to the owning source.
  """
  @spec dispatch_by_bot_name(atom(), term()) :: term()
  def dispatch_by_bot_name(bot_name, event) when is_atom(bot_name) do
    case Registry.lookup(@registry, {:bot, bot_name}) do
      [{pid, _value}] when is_pid(pid) ->
        GenServer.call(pid, {:event, event}, 30_000)

      [] ->
        {:error,
         Error.payload("Discord channel for bot is not started", %{
           "bot_name" => Atom.to_string(bot_name)
         })}
    end
  end

  @impl true
  def init(%Source{} = source) do
    Logger.info("discord source start",
      adapter: source.adapter,
      channel_id: source.channel_id,
      transport: "gateway"
    )

    case register_bot(source) do
      :ok ->
        {:ok, %__MODULE__{source: source, bot_user_id: source.bot_user_id, ready?: false}}

      {:error, error} ->
        {:stop, {:discord_channel_init_failed, error}}
    end
  end

  @impl true
  def handle_call({:event, event}, _from, %__MODULE__{} = state) do
    {reply, state} = dispatch(event, state)
    {:reply, reply, state}
  end

  def handle_call(:bot_identity, _from, %__MODULE__{} = state) do
    {:reply, %{bot_user_id: state.bot_user_id, ready?: state.ready?}, state}
  end

  defp register_bot(%Source{bot_name: bot_name, channel_id: channel_id}) do
    case Registry.register(@registry, {:bot, bot_name}, channel_id) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        :ok

      {:error, reason} ->
        {:error, Error.unknown("discord registry register failed: #{inspect(reason)}")}
    end
  end

  defp dispatch({:READY, ready, _ws_state}, %__MODULE__{} = state) do
    user = field(ready, :user)
    bot_user_id = bot_user_id(user)
    source = put_bot_user_id(state.source, bot_user_id)

    Logger.info("discord ready",
      channel_id: source.channel_id,
      bot_user_id: bot_user_id
    )

    :telemetry.execute(
      [:bullx, :discord, :gateway, :ready],
      %{count: 1},
      %{channel_id: source.channel_id, bot_user_id: bot_user_id}
    )

    sync_application_commands(source)

    {{:ok, %{status: :ready}}, %{state | source: source, bot_user_id: bot_user_id, ready?: true}}
  end

  defp dispatch({:MESSAGE_CREATE, payload, _ws_state}, %__MODULE__{} = state) do
    process_event(payload, "message_create", state)
  end

  defp dispatch({:MESSAGE_UPDATE, payload, _ws_state}, %__MODULE__{} = state) do
    process_event(payload, "message_update", state)
  end

  defp dispatch({:INTERACTION_CREATE, payload, _ws_state}, %__MODULE__{} = state) do
    process_event(payload, "interaction_create", state)
  end

  defp dispatch(_event, %__MODULE__{} = state) do
    {{:ok, %{status: :ignored, reason: :unsupported_event}}, state}
  end

  defp sync_application_commands(%Source{} = source) do
    case ApplicationCommands.sync(source) do
      {:ok, result} ->
        :telemetry.execute(
          [:bullx, :discord, :application_commands, :sync],
          %{count: 1},
          %{channel_id: source.channel_id, result: :ok}
        )

        Logger.info("discord application_commands sync",
          channel_id: source.channel_id,
          status: inspect(result)
        )

      {:error, error} ->
        :telemetry.execute(
          [:bullx, :discord, :application_commands, :sync],
          %{count: 1},
          %{channel_id: source.channel_id, result: :error}
        )

        Logger.warning("discord application_commands sync failed",
          channel_id: source.channel_id,
          error: inspect(error)
        )
    end
  end

  defp process_event(payload, event_type, %__MODULE__{} = state) do
    :telemetry.execute(
      [:bullx, :discord, :event, :received],
      %{count: 1},
      %{channel_id: state.source.channel_id, event_type: event_type}
    )

    case EventMapper.map_event(payload, event_type, state.source) do
      {:ignore, reason} ->
        emit_ignored(reason, state.source)
        {{:ok, %{status: :ignored, reason: reason}}, state}

      {:direct_command, command} ->
        handle_direct_command(command, state)

      {:ok, mapped} ->
        run_publish_pipeline(mapped, state)

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp handle_direct_command(command, %__MODULE__{} = state) do
    case DirectCommand.handle(command, state.source) do
      {:ok, result} -> {{:ok, %{status: :direct_command, result: result}}, state}
      {:error, error} -> {{:error, error}, state}
    end
  end

  defp run_publish_pipeline(mapped, %__MODULE__{} = state) do
    case state.source.accounts_module.match_or_create_human_from_channel(mapped.account_input) do
      {:ok, _principal, _identity} ->
        publish_after_gate(mapped, state)

      {:error, :activation_required} ->
        reply_account_gate(mapped, state, activation_required_text(mapped), "activation_required")

      {:error, :principal_disabled} ->
        reply_account_gate(mapped, state, BullX.I18n.t("gateway.discord.auth.denied"), "denied")

      {:error, reason} when is_map(reason) ->
        {{:error, reason}, state}

      {:error, reason} ->
        {{:error, Error.map(reason)}, state}
    end
  end

  defp publish_after_gate(mapped, %__MODULE__{} = state) do
    with {:ok, mapped} <- AskCommand.acknowledge_if_interaction(mapped, state.source),
         {:ok, mapped} <- ThreadOwnership.maybe_auto_thread(mapped, state.source) do
      gateway_publish(mapped.input, state)
    else
      {:error, error} -> {{:error, error}, state}
    end
  end

  defp gateway_publish(input, %__MODULE__{} = state) do
    :telemetry.execute(
      [:bullx, :discord, :event, :publish, :start],
      %{system_time: System.system_time()},
      %{channel_id: state.source.channel_id}
    )

    case state.source.gateway_module.publish(state.source.source_config, input) do
      {:ok, :accepted, _signal, _mailbox} ->
        :telemetry.execute(
          [:bullx, :discord, :event, :publish, :stop],
          %{count: 1},
          %{channel_id: state.source.channel_id, result: :accepted}
        )

        {{:ok, :accepted}, state}

      {:error, error} ->
        :telemetry.execute(
          [:bullx, :discord, :event, :publish, :stop],
          %{count: 1},
          %{channel_id: state.source.channel_id, result: :error}
        )

        {{:error, Error.map(error)}, state}
    end
  end

  defp reply_account_gate(mapped, %__MODULE__{} = state, text, command_name) do
    command = synthetic_reply_command(mapped, state.source, command_name)

    case DirectCommand.reply_text(command, state.source, text, command_name) do
      {:ok, _result} ->
        {{:ok, %{status: :account_gate, reason: command_name}}, state}

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp synthetic_reply_command(%{} = mapped, %Source{} = source, command_name) do
    context = Map.get(mapped, :context, %{})
    interaction = Map.get(mapped, :interaction)

    %{
      name: command_name,
      args: "",
      transport: if(interaction, do: :interaction, else: :message),
      event_id: Map.get(context, :event_id) || mapped.input["occurrence_key"] || "unknown",
      channel_id: source.channel_id,
      scope_id: mapped.input["scope_id"],
      discord_channel_id: Map.get(context, :discord_channel_id) || mapped.input["scope_id"],
      guild_id: Map.get(context, :guild_id),
      message_id: get_in(mapped.input, ["reply_channel", "reply_to_external_id"]),
      actor: %{id: get_in(mapped.input, ["actor", "id"])},
      account_input: mapped.account_input,
      interaction: interaction,
      dm?: is_nil(Map.get(context, :guild_id))
    }
  end

  defp activation_required_text(mapped) do
    case Map.get(mapped.context, :guild_id) do
      nil -> BullX.I18n.t("gateway.discord.auth.activation_required")
      _guild -> BullX.I18n.t("gateway.discord.auth.direct_command_dm_only")
    end
  end

  defp emit_ignored(reason, %Source{channel_id: channel_id}) do
    :telemetry.execute(
      [:bullx, :discord, :event, :ignored],
      %{count: 1},
      %{channel_id: channel_id, reason: reason}
    )
  end

  defp bot_user_id(%{} = user) do
    case field(user, :id) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value -> to_string(value)
    end
  end

  defp bot_user_id(_user), do: nil

  defp put_bot_user_id(%Source{} = source, nil), do: source

  defp put_bot_user_id(%Source{} = source, bot_user_id) when is_binary(bot_user_id) do
    %{source | bot_user_id: bot_user_id}
  end

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
