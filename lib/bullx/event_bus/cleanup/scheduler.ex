defmodule BullX.EventBus.Cleanup.Scheduler do
  @moduledoc """
  Periodic cleanup entry point for weak EventBus runtime records.

  Cleanup is operational maintenance for reconstructible TargetSession state. It
  must not create business facts or infer Target progress.
  """

  use GenServer

  alias BullX.EventBus.{Cleanup, Config}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Config.target_session_cleanup_interval_ms() do
      false ->
        :ignore

      interval_ms ->
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, interval_ms, name: name)
    end
  end

  @impl true
  def init(interval_ms) do
    send(self(), :run_cleanup)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:run_cleanup, %{interval_ms: interval_ms} = state) do
    Cleanup.run()
    Process.send_after(self(), :run_cleanup, interval_ms)
    {:noreply, state}
  end
end
