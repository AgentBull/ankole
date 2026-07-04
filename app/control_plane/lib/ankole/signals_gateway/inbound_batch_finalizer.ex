defmodule Ankole.SignalsGateway.InboundBatchFinalizer do
  @moduledoc """
  SignalsGateway-owned poller for IM inbound batch quiet-window finalization.

  ActorRuntime consumes already-created actor events; it should not own the
  debounce clock that decides when provider ingress becomes an actor event.
  """

  use GenServer, restart: :permanent

  require Logger

  alias Ankole.SignalsGateway

  @default_interval_ms 500
  @default_limit 25

  @doc """
  Runs one bounded finalization pass.
  """
  @spec run_once(keyword()) :: {:ok, [map()]}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, @default_limit)

    SignalsGateway.finalize_due_inbound_batches(now: now, limit: limit)
  end

  @doc """
  Wakes the singleton poller after ingress mutates pending batch state.
  """
  @spec wake() :: :ok
  def wake do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :wake)
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      limit: Keyword.get(opts, :limit, @default_limit)
    }

    {:ok, state, {:continue, :initial_poll}}
  end

  @impl true
  def handle_continue(:initial_poll, state) do
    poll(state)
    schedule_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:wake, state) do
    poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll(state)
    schedule_next(state)
    {:noreply, state}
  end

  defp poll(state) do
    {:ok, _results} = run_once(limit: state.limit)
    :ok
  rescue
    error ->
      Logger.warning(
        "signals_gateway inbound batch finalizer failed: #{Exception.message(error)}"
      )
  end

  defp schedule_next(state) do
    Process.send_after(self(), :poll, state.interval_ms)
  end
end
