defmodule BullxTelegram.Poller do
  @moduledoc """
  Long-poll worker for one Telegram source.

  Calls `getUpdates` with the configured timeout/limit and dispatches each
  update through `BullxTelegram.Channel.handle_update/2`. On transient
  failure (network, timeout, rate limit) it backs off up to `poll_retry_max`
  attempts. A persistent `getUpdates` conflict (409) is terminal: the poller
  crashes with `:telegram_polling_conflict` and relies on supervisor
  escalation rather than silent retry.
  """

  use GenServer

  require Logger

  alias BullxTelegram.{Channel, Error, Source}

  @allowed_updates ["message", "edited_message"]

  defstruct [:source, offset: nil, retry_count: 0]

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

  defp via(%Source{channel_id: channel_id}) do
    {:via, Registry, {BullxTelegram.Registry, {:poller, channel_id}}}
  end

  @impl true
  def init(%Source{start_transport?: false} = source) do
    {:ok, %__MODULE__{source: source}}
  end

  def init(%Source{} = source) do
    Process.flag(:trap_exit, false)
    {:ok, %__MODULE__{source: source}, {:continue, :start_polling}}
  end

  @impl true
  def handle_continue(:start_polling, %__MODULE__{source: source} = state) do
    case Source.request(source, "deleteWebhook", drop_pending_updates: false) do
      {:ok, _result} ->
        Logger.info("telegram polling started",
          adapter: source.adapter,
          channel_id: source.channel_id
        )

        send(self(), :poll)
        {:noreply, state}

      {:error, error} ->
        {:stop, {:telegram_polling_start_failed, Error.map(error)}, state}
    end
  end

  @impl true
  def handle_info(:poll, %__MODULE__{} = state) do
    case poll_once(state) do
      {:ok, state} ->
        send(self(), :poll)
        {:noreply, state}

      {:error, error, state} ->
        retry_or_crash(error, state)
    end
  end

  defp poll_once(%__MODULE__{} = state) do
    params =
      [
        timeout: state.source.poll_timeout_s,
        limit: state.source.poll_limit,
        allowed_updates: {:json, @allowed_updates}
      ]
      |> maybe_put(:offset, state.offset)

    case Source.request(state.source, "getUpdates", params) do
      {:ok, updates} when is_list(updates) -> dispatch_updates(updates, state)
      {:error, error} -> {:error, error, state}
    end
  end

  defp dispatch_updates([], state), do: {:ok, %{state | retry_count: 0}}

  defp dispatch_updates([update | rest], state) do
    {:ok, state} = dispatch_update(update, state)
    dispatch_updates(rest, state)
  end

  defp dispatch_update(update, %__MODULE__{} = state) do
    next_offset = update |> Map.get("update_id") |> next_offset()

    try do
      _result = Channel.handle_update(state.source, update)
      {:ok, %{state | offset: next_offset, retry_count: 0}}
    catch
      kind, reason ->
        Logger.error("telegram channel update dispatch failed",
          channel_id: state.source.channel_id,
          kind: kind,
          reason: inspect(reason)
        )

        # Advance offset even on dispatch error so we do not refetch the same
        # malformed update forever. Adapter-level dispatch errors are not
        # retryable through `getUpdates`.
        {:ok, %{state | offset: next_offset}}
    end
  end

  defp retry_or_crash(error, %__MODULE__{} = state) do
    cond do
      Error.polling_conflict?(error) ->
        :telemetry.execute(
          [:bullx, :telegram, :poller, :conflict],
          %{count: 1},
          %{channel_id: state.source.channel_id}
        )

        {:stop, {:telegram_polling_conflict, Error.map(error)}, state}

      state.retry_count >= state.source.poll_retry_max ->
        {:stop, {:telegram_polling_failed, Error.map(error)}, state}

      true ->
        backoff = backoff_ms(state.retry_count)

        :telemetry.execute(
          [:bullx, :telegram, :poller, :retry],
          %{retry_count: state.retry_count, backoff_ms: backoff},
          %{channel_id: state.source.channel_id}
        )

        Process.send_after(self(), :poll, backoff)
        {:noreply, %{state | retry_count: state.retry_count + 1}}
    end
  end

  defp backoff_ms(retry_count) do
    base = 250
    max = 30_000
    candidate = base * :erlang.bsl(1, min(retry_count, 8))
    min(candidate, max)
  end

  defp next_offset(nil), do: nil
  defp next_offset(update_id) when is_integer(update_id), do: update_id + 1
  defp next_offset(_other), do: nil

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
