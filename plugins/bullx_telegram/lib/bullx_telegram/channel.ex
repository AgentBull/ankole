defmodule BullxTelegram.Channel do
  @moduledoc """
  Source-local runtime boundary for one configured Telegram source.

  Owns bot identity resolution at startup (`getMe`), the optional command-menu
  sync, dispatcher wiring, and the local `BullX.Cache`-backed direct-command
  dedupe and message-context state. `Telegram.Poller` calls
  `handle_update/2` for each accepted update; the channel runs mapping,
  attention filtering, direct-command interception, Principal gating, and
  Gateway publish.
  """

  use GenServer

  require Logger

  alias BullxTelegram.{Commands, DirectCommand, Error, Source, UpdateMapper}

  defstruct [:source, :bot_id, :bot_username]

  @type via :: {:via, Registry, {BullxTelegram.Registry, term()}}

  @registry BullxTelegram.Registry

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

  @spec handle_update(Source.t() | via() | binary(), map(), timeout()) :: term()
  def handle_update(target, update, timeout \\ 30_000)

  def handle_update(%Source{} = source, update, timeout) do
    GenServer.call(via(source), {:update, update}, timeout)
  end

  def handle_update({:via, _registry, _key} = via, update, timeout) do
    GenServer.call(via, {:update, update}, timeout)
  end

  def handle_update(channel_id, update, timeout) when is_binary(channel_id) do
    GenServer.call(via(channel_id), {:update, update}, timeout)
  end

  @spec via(Source.t() | binary()) :: via()
  def via(%Source{channel_id: channel_id}), do: via(channel_id)
  def via(channel_id) when is_binary(channel_id), do: {:via, Registry, {@registry, channel_id}}

  @impl true
  def init(%Source{} = source) do
    Logger.info("telegram source start",
      adapter: source.adapter,
      channel_id: source.channel_id,
      transport: "polling"
    )

    case startup(source) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:stop, {:telegram_channel_init_failed, error}}
    end
  end

  @impl true
  def handle_call({:update, update}, _from, %__MODULE__{} = state) do
    {:reply, dispatch_update(update, state), state}
  end

  def handle_call(:bot_identity, _from, %__MODULE__{} = state) do
    {:reply, %{bot_id: state.bot_id, bot_username: state.bot_username}, state}
  end

  defp startup(%Source{start_transport?: false} = source) do
    {:ok, %__MODULE__{source: source}}
  end

  defp startup(%Source{} = source) do
    with {:ok, bot} <- fetch_bot_identity(source),
         source = put_bot_identity(source, bot),
         :ok <- Commands.sync(source) do
      {:ok,
       %__MODULE__{
         source: source,
         bot_id: source.bot_id,
         bot_username: source.bot_username
       }}
    end
  end

  defp fetch_bot_identity(%Source{} = source) do
    case Source.request(source, "getMe") do
      {:ok, %{} = bot} -> {:ok, bot}
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp put_bot_identity(%Source{} = source, bot) do
    bot_id = bot |> Map.get("id") |> to_string_or_nil()
    bot_username = bot |> Map.get("username") |> present_string()

    %{
      source
      | bot_id: bot_id,
        bot_username: source.bot_username || bot_username
    }
  end

  defp dispatch_update(update, %__MODULE__{source: source} = state) do
    :telemetry.execute(
      [:bullx, :telegram, :update, :received],
      %{count: 1},
      %{channel_id: source.channel_id, bot_id: state.bot_id}
    )

    case UpdateMapper.map_update(update, source) do
      {:ignore, reason} ->
        emit_ignored(reason, source)
        {:ok, %{status: :ignored, reason: reason}}

      {:direct_command, command} ->
        handle_direct_command(command, source)

      {:ok, %{input: input, account_input: account_input}} ->
        publish_input(input, account_input, source)

      {:error, error} ->
        {:error, error}
    end
  end

  defp handle_direct_command(command, %Source{} = source) do
    case DirectCommand.handle(command, source) do
      {:ok, result} -> {:ok, %{status: :direct_command, result: result}}
      {:error, error} -> {:error, error}
    end
  end

  defp publish_input(input, account_input, %Source{} = source) do
    with {:ok, _principal, _identity} <-
           BullX.Principals.match_or_create_human_from_channel(account_input),
         {:ok, :accepted, _signal, _mailbox} <- BullX.Gateway.publish(source.source_config, input) do
      :telemetry.execute(
        [:bullx, :telegram, :update, :publish, :stop],
        %{count: 1},
        %{channel_id: source.channel_id, result: :accepted}
      )

      {:ok, :accepted}
    else
      {:error, :activation_required} -> maybe_reply_activation_required(input, source)
      {:error, :principal_disabled} -> maybe_reply(input, source, BullX.I18n.t("gateway.telegram.auth.denied"))
      {:error, error} when is_map(error) -> {:error, error}
      {:error, reason} -> {:error, Error.map(reason)}
    end
  end

  defp maybe_reply_activation_required(input, %Source{} = source) do
    case get_in(input, ["event", "data", "chat_type"]) do
      "private" ->
        maybe_reply(input, source, BullX.I18n.t("gateway.telegram.auth.activation_required"))

      _other ->
        {:ok, :activation_required}
    end
  end

  defp maybe_reply(input, %Source{} = source, text) do
    command = %{
      event_id:
        get_in(input, ["provenance", "update_id"]) || input["occurrence_key"] || "unknown",
      chat_id: input["scope_id"],
      chat_type: get_in(input, ["event", "data", "chat_type"]),
      thread_id: input["thread_id"],
      message_id: get_in(input, ["reply_channel", "reply_to_external_id"]),
      actor: %{id: get_in(input, ["actor", "id"])}
    }

    DirectCommand.reply_text(command, source, text, "account_gate")
  end

  defp emit_ignored(reason, %Source{channel_id: channel_id}) do
    :telemetry.execute(
      [:bullx, :telegram, :update, :ignored],
      %{count: 1},
      %{channel_id: channel_id, reason: reason}
    )
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(value) when is_binary(value) and value != "", do: value
  defp to_string_or_nil(_value), do: nil

  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_value), do: nil
end
