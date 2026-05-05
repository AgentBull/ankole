defmodule BullXDiscord.Channel do
  @moduledoc false

  use GenServer
  require Logger

  alias BullXDiscord.{Cache, Config, Consumer}

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

  def bot_child_spec({_channel, %Config{start_transport?: false}}), do: nil

  def bot_child_spec({channel, %Config{} = config}) do
    config.nostrum_bot_module.child_spec(
      {Config.bot_options(config),
       [
         strategy: :one_for_one,
         name: {:via, Registry, {BullXGateway.AdapterSupervisor.Registry, {Nostrum.Bot, channel}}}
       ]}
    )
  end

  def handle_event_by_bot_name(bot_name, event) do
    case Registry.lookup(
           BullXGateway.AdapterSupervisor.Registry,
           {__MODULE__, :bot_name, bot_name}
         ) do
      [{pid, _value}] when is_pid(pid) -> GenServer.call(pid, {:event, event}, 30_000)
      [] -> {:error, BullXDiscord.Error.payload("Discord channel is not started")}
    end
  end

  def handle_event(channel, event) do
    GenServer.call(via(channel), {:event, event}, 30_000)
  end

  @impl true
  def init({channel, config}) do
    {:ok, cfg} = Config.normalize(channel, config)
    :ok = register_bot_name(cfg)

    Logger.info("discord channel start requested",
      channel: :discord,
      channel_id: cfg.channel_id,
      bot_name: cfg.bot_name,
      transport: :gateway
    )

    {:ok, %__MODULE__{channel: channel, config: cfg, cache: Cache.new()}}
  end

  @impl true
  def handle_call({:event, event}, _from, state) do
    {reply, state} = Consumer.handle_event(event, state)
    {:reply, reply, state}
  end

  defp via(channel),
    do: {:via, Registry, {BullXGateway.AdapterSupervisor.Registry, {__MODULE__, channel}}}

  defp register_bot_name(%Config{bot_name: bot_name, channel: channel}) do
    case Registry.register(
           BullXGateway.AdapterSupervisor.Registry,
           {__MODULE__, :bot_name, bot_name},
           channel
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end
end
