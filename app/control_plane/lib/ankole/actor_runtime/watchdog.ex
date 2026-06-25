defmodule Ankole.ActorRuntime.Watchdog do
  @moduledoc """
  Periodic recovery owner for stale workers, expired leases, and projection gaps.

  The watchdog is the heartbeat-lease enforcer for the runtime. Each tick runs
  idempotent, repeatable repairs against the durable ledger: expire workers whose
  heartbeats lapsed, release activation leases past their deadline, and re-derive
  runtime projections for durable turns that lost theirs (e.g. after a control-
  plane restart). Because every pass re-reads the database and only ever moves
  state toward consistency, missing or doubling a tick is harmless — which is why
  failures are logged and the loop simply keeps going.
  """

  use GenServer

  require Logger

  alias Ankole.ActorRuntime

  # Recovery cadence. 1s keeps lease/heartbeat expiry latency low (an actor stuck
  # behind a dead worker recovers within ~a second) while the queries are cheap
  # enough to run that often. Operators can raise it via :interval_ms.
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
      # Declare a worker dead after 60s without a heartbeat — several missed
      # ~heartbeat intervals, so a brief network blip doesn't evict a live worker,
      # but a truly gone worker's in-flight turns are freed within a minute.
      stale_after_seconds: Keyword.get(opts, :stale_after_seconds, 60),
      # Keep stale/stopped worker rows for 1h before deleting them, so operators
      # can still see why a worker dropped out before the projection is reaped.
      stale_worker_ttl_seconds: Keyword.get(opts, :stale_worker_ttl_seconds, 3_600),
      # No extra slack past a lease deadline by default; tunable if clock skew
      # between control plane and workers ever needs absorbing.
      lease_grace_seconds: Keyword.get(opts, :lease_grace_seconds, 0)
    }

    # Run one pass immediately on boot (via continue) so recovery doesn't wait a
    # full interval after a control-plane restart, then settle into the timer loop.
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
