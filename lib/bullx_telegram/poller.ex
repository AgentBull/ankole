defmodule BullXTelegram.Poller do
  @moduledoc false

  use GenServer
  require Logger

  alias BullX.Retry
  alias BullXTelegram.{Channel, Commands, Config, Error}

  @retry_policy_opts %{base_backoff_ms: 250, max_backoff_ms: 30_000}
  @retry_error %{"kind" => "network"}

  defstruct [:channel, :config, offset: nil, retry_count: 0]

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

  @impl true
  def init({channel, config}) do
    with {:ok, cfg} <- Config.normalize(channel, config),
         :ok <- register_bot_token_lock(cfg) do
      {:ok, %__MODULE__{channel: channel, config: cfg}, {:continue, :start_polling}}
    else
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_continue(:start_polling, state) do
    with {:ok, _} <- Config.request(state.config, "deleteWebhook", drop_pending_updates: false),
         {:ok, _bot} <- Config.request(state.config, "getMe"),
         {:ok, _commands} <- Commands.sync(state.config) do
      Logger.info("telegram polling started",
        channel: :telegram,
        channel_id: state.config.channel_id
      )

      send(self(), :poll)
      {:noreply, state}
    else
      {:error, error} ->
        {:stop, {:telegram_polling_start_failed, Error.map(error)}, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case poll_once(state) do
      {:ok, state} ->
        send(self(), :poll)
        {:noreply, state}

      {:error, error, state} ->
        retry_or_crash(error, state)
    end
  end

  defp poll_once(state) do
    params =
      [
        timeout: state.config.poll_timeout_s,
        limit: state.config.poll_limit,
        allowed_updates: {:json, ["message", "edited_message"]}
      ]
      |> maybe_put(:offset, state.offset)

    case Config.request(state.config, "getUpdates", params) do
      {:ok, updates} when is_list(updates) ->
        dispatch_updates(updates, state)

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp dispatch_updates(updates, state) do
    updates
    |> Enum.reduce_while({:ok, state}, fn update, {:ok, state} ->
      case dispatch_update(update, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error, state} -> {:halt, {:error, error, state}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, %{state | retry_count: 0}}
      {:error, error, state} -> {:error, error, state}
    end
  end

  defp dispatch_update(update, state) do
    case Channel.handle_update(state.channel, update) do
      {:ok, _result} ->
        {:ok, advance_offset(state, update)}

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp advance_offset(state, update) do
    case update_id(update) do
      nil -> state
      id -> %{state | offset: id + 1}
    end
  end

  defp retry_or_crash(error, state) do
    cond do
      Error.polling_conflict?(error) and state.retry_count >= state.config.poll_retry_max ->
        {:stop, {:telegram_polling_conflict, Error.map(error)}, state}

      state.retry_count >= state.config.poll_retry_max ->
        {:stop, {:telegram_polling_failed, Error.map(error)}, state}

      true ->
        Logger.warning("telegram polling retry",
          channel: :telegram,
          channel_id: state.config.channel_id,
          retry_count: state.retry_count + 1,
          error: inspect(Error.map(error))
        )

        Process.send_after(self(), :poll, retry_delay_ms(state.retry_count))
        {:noreply, %{state | retry_count: state.retry_count + 1}}
    end
  end

  defp retry_delay_ms(retry_count) do
    # Reuse BullX.Retry's exponential schedule and keep poller-private jitter
    # so long-polling reconnections desynchronize across instances.
    base = Retry.backoff_ms(Retry.build(@retry_policy_opts), @retry_error, retry_count + 1)
    base + :rand.uniform(max(1, div(base, 2)))
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp update_id(update) do
    case field(update, :update_id) do
      id when is_integer(id) -> id
      id when is_binary(id) -> id |> Integer.parse() |> parsed_integer()
      _other -> nil
    end
  end

  defp parsed_integer({value, ""}), do: value
  defp parsed_integer(_other), do: nil

  defp register_bot_token_lock(%Config{} = config) do
    token =
      config.bot_token
      |> Config.secret_value()
      |> token_lock_key()

    case Registry.register(BullXGateway.AdapterSupervisor.Registry, token, config.channel) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        {:error,
         {:telegram_polling_conflict,
          Error.config("Telegram bot token already has a polling process", %{
            "field" => "bot_token",
            "channel_id" => config.channel_id
          })}}
    end
  end

  defp token_lock_key(token) when is_binary(token) do
    {__MODULE__, :bot_token, BullX.Ext.generic_hash(token)}
  end

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp via(channel),
    do: {:via, Registry, {BullXGateway.AdapterSupervisor.Registry, {__MODULE__, channel}}}
end
