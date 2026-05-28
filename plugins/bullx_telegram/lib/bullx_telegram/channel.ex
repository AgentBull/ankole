defmodule BullxTelegram.Channel do
  @moduledoc false

  use GenServer

  require Logger

  alias BullxTelegram.{Commands, Source}

  defstruct [:source]

  @registry BullxTelegram.Registry

  @spec child_spec(Source.t()) :: Supervisor.child_spec()
  def child_spec(%Source{} = source) do
    %{
      id: {__MODULE__, source.id},
      start: {__MODULE__, :start_link, [source]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(Source.t()) :: GenServer.on_start()
  def start_link(%Source{} = source), do: GenServer.start_link(__MODULE__, source, name: via(source))

  @spec handle_update(Source.t() | String.t(), map(), timeout()) :: term()
  def handle_update(target, update, timeout \\ 30_000)
  def handle_update(%Source{} = source, update, timeout), do: GenServer.call(via(source), {:update, update}, timeout)
  def handle_update(source_id, update, timeout) when is_binary(source_id), do: GenServer.call(via(source_id), {:update, update}, timeout)

  defp via(%Source{id: id}), do: via(id)
  defp via(id) when is_binary(id), do: {:via, Registry, {@registry, {:channel, id}}}

  @impl true
  def init(%Source{} = source) do
    Logger.info("telegram source start", source_id: source.id, transport: "polling")

    case startup(source) do
      {:ok, source} -> {:ok, %__MODULE__{source: source}}
      {:error, error} -> {:stop, {:telegram_channel_init_failed, error}}
    end
  end

  @impl true
  def handle_call({:update, update}, _from, %__MODULE__{source: source} = state) do
    result = BullX.IMGateway.ChannelAdapter.accept_inbound("telegram", source, update)
    {:reply, result, state}
  end

  def handle_call(:source, _from, %__MODULE__{source: source} = state), do: {:reply, source, state}

  defp startup(%Source{start_transport?: false} = source), do: {:ok, source}

  defp startup(%Source{} = source) do
    with {:ok, bot} <- Source.request(source, "getMe"),
         {:ok, source} <- put_bot_identity(source, bot),
         :ok <- Commands.sync(source) do
      {:ok, source}
    else
      {:error, error} -> {:error, BullxTelegram.Error.map(error)}
    end
  end

  defp put_bot_identity(%Source{} = source, %{} = bot) do
    bot_id = stringify_id(Map.get(bot, "id")) || source.bot_id
    bot_username = present_string(Map.get(bot, "username")) || source.bot_username

    case source.bot_username && bot_username && String.downcase(source.bot_username) != String.downcase(bot_username) do
      true ->
        {:error,
         BullxTelegram.Error.config("Telegram bot_username mismatch", %{
           expected: source.bot_username,
           actual: bot_username
         })}

      false ->
        {:ok, %{source | bot_id: bot_id, bot_username: bot_username}}
    end
  end

  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(value) when is_binary(value), do: value
  defp stringify_id(_value), do: nil
  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_value), do: nil
end
