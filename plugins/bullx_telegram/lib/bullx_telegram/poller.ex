defmodule BullxTelegram.Poller do
  @moduledoc false

  use GenServer

  require Logger

  alias BullxTelegram.{Channel, Error, Source}

  import BullX.Utils.Map, only: [maybe_put: 3]

  @allowed_updates ["message", "edited_message"]

  defstruct [:source, offset: nil, retry_count: 0]

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
  def start_link(%Source{} = source) do
    GenServer.start_link(__MODULE__, source, name: {:via, Registry, {@registry, {:poller, source.id}}})
  end

  @impl true
  def init(%Source{start_transport?: false} = source), do: {:ok, %__MODULE__{source: source}}

  def init(%Source{} = source), do: {:ok, %__MODULE__{source: source}, {:continue, :start_polling}}

  @impl true
  def handle_continue(:start_polling, %__MODULE__{source: source} = state) do
    case Source.request(source, "deleteWebhook", %{"drop_pending_updates" => false}) do
      {:ok, _result} ->
        Logger.info("telegram polling started", source_id: source.id)
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
      %{
        "timeout" => state.source.poll_timeout_s,
        "limit" => state.source.poll_limit,
        "allowed_updates" => @allowed_updates
      }
      |> maybe_put("offset", state.offset)

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
    _result = Channel.handle_update(state.source, update)
    {:ok, %{state | offset: next_offset, retry_count: 0}}
  catch
    _kind, _reason ->
      {:ok, %{state | offset: update |> Map.get("update_id") |> next_offset()}}
  end

  defp retry_or_crash(error, %__MODULE__{} = state) do
    cond do
      Error.polling_conflict?(error) ->
        :telemetry.execute(
          [:bullx, :im_gateway, :adapter, :telegram, :poller, :conflict],
          %{count: 1},
          %{source_id: state.source.id}
        )

        {:stop, {:telegram_polling_conflict, Error.map(error)}, state}

      state.retry_count >= state.source.poll_retry_max ->
        {:stop, {:telegram_polling_failed, Error.map(error)}, state}

      true ->
        backoff = backoff_ms(state.retry_count)

        :telemetry.execute(
          [:bullx, :im_gateway, :adapter, :telegram, :poller, :retry],
          %{retry_count: state.retry_count, backoff_ms: backoff},
          %{source_id: state.source.id}
        )

        Process.send_after(self(), :poll, backoff)
        {:noreply, %{state | retry_count: state.retry_count + 1}}
    end
  end

  defp backoff_ms(retry_count), do: min(250 * :erlang.bsl(1, min(retry_count, 8)), 30_000)
  defp next_offset(nil), do: nil
  defp next_offset(update_id) when is_integer(update_id), do: update_id + 1
  defp next_offset(_value), do: nil
end
