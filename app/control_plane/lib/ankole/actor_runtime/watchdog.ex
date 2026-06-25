defmodule Ankole.ActorRuntime.Watchdog do
  @moduledoc """
  Periodic recovery owner for stale workers, expired leases, and projection gaps.
  """

  use GenServer

  require Logger

  alias Ankole.ActorRuntime

  @default_interval_ms 1_000

  @doc """
  Starts the watchdog.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one watchdog pass.

  The watchdog owns repair work that is safe to repeat: stale workers, expired
  activation leases, and durable turns whose runtime projections disappeared.
  """
  @spec run_once(keyword()) :: {:ok, map()} | {:error, term()}
  def run_once(opts \\ []), do: ActorRuntime.watchdog_once(opts)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      stale_after_seconds: Keyword.get(opts, :stale_after_seconds, 60),
      stale_worker_ttl_seconds: Keyword.get(opts, :stale_worker_ttl_seconds, 3_600),
      lease_grace_seconds: Keyword.get(opts, :lease_grace_seconds, 0)
    }

    {:ok, state, {:continue, :initial_watchdog}}
  end

  @impl true
  def handle_continue(:initial_watchdog, state) do
    run(state)
    schedule_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:watchdog, state) do
    run(state)
    schedule_next(state)
    {:noreply, state}
  end

  # Logs and keeps scheduling after failures. Recovery should be persistent, not
  # dependent on one successful watchdog tick.
  defp run(state) do
    case run_once(
           stale_after_seconds: state.stale_after_seconds,
           stale_worker_ttl_seconds: state.stale_worker_ttl_seconds,
           lease_grace_seconds: state.lease_grace_seconds
         ) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning("actor runtime watchdog failed: #{inspect(reason)}")
    end
  end

  defp schedule_next(state) do
    Process.send_after(self(), :watchdog, state.interval_ms)
  end
end
