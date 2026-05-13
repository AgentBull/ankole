defmodule BullX.Gateway.Outbound.RetentionWorker do
  @moduledoc false

  use GenServer

  alias BullX.Gateway.Outbound.{Finalizer, Store}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(opts, :interval_ms, gateway_config(:stream_retention_interval_ms, 60_000)),
      batch_size:
        Keyword.get(opts, :batch_size, gateway_config(:stream_retention_batch_size, 500))
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:expire, state) do
    recovered_count = recover_terminal_streams(state.batch_size)
    count = Store.expired_stream_cleanup(state.batch_size)

    :telemetry.execute(
      [:bullx, :gateway, :stream_buffer, :expire],
      %{count: count, recovered_count: recovered_count},
      %{}
    )

    {:noreply, schedule(state)}
  end

  defp recover_terminal_streams(batch_size) do
    batch_size
    |> Store.terminalizing_streams()
    |> Enum.reduce(0, fn stream_id, count ->
      case Finalizer.finalize_stream(stream_id) do
        :ok -> count + 1
        {:error, _reason} -> count
      end
    end)
  end

  defp schedule(%{interval_ms: false} = state), do: state

  defp schedule(state) do
    Process.send_after(self(), :expire, state.interval_ms)
    state
  end

  defp gateway_config(key, default) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(key, default)
  end
end
