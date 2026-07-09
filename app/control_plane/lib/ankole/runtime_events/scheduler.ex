defmodule Ankole.RuntimeEvents.Scheduler do
  @moduledoc false

  use GenServer

  alias Ankole.Logging
  alias Ankole.RuntimeEvents
  alias Ankole.RuntimeEvents.Event
  alias Ankole.RuntimeEvents.Handlers

  @default_sweep_interval_ms :timer.minutes(1)

  @type timer_key :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec notify(GenServer.server(), String.t(), map()) :: :ok
  def notify(server \\ __MODULE__, channel, payload) do
    GenServer.cast(server, {:notify, channel, payload})
  end

  @spec hydrate(GenServer.server()) :: :ok
  def hydrate(server \\ __MODULE__) do
    GenServer.cast(server, :hydrate)
  end

  @impl true
  def init(opts) do
    with {:ok, sweep_interval_ms} <- sweep_interval_ms(opts) do
      Process.send_after(self(), :sweep, sweep_interval_ms)

      {:ok,
       %{
         task_supervisor:
           Keyword.get(opts, :task_supervisor, Ankole.RuntimeEvents.TaskSupervisor),
         timers: %{},
         sweep_interval_ms: sweep_interval_ms
       }}
    end
  end

  @impl true
  def handle_cast(:hydrate, state) do
    {:noreply, hydrate_state(state)}
  end

  @impl true
  def handle_cast({:notify, channel, payload}, state) do
    {:noreply, schedule_or_run(state, channel, payload)}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = hydrate_state_for_sweep(state)
    Process.send_after(self(), :sweep, state.sweep_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:deadline, key, ref}, state) do
    case Map.get(state.timers, key) do
      %{ref: ^ref, event: event} ->
        state = %{state | timers: Map.delete(state.timers, key)}
        run_handler(state, event)
        {:noreply, state}

      _stale_timer ->
        {:noreply, state}
    end
  end

  defp hydrate_state(state) do
    snapshot_events(state)
    |> Enum.reduce(state, fn {channel, payload}, acc ->
      schedule_or_run(acc, channel, payload)
    end)
  end

  defp snapshot_events(state) do
    snapshot_events = Map.get(state, :snapshot_events, &Handlers.snapshot_events/0)
    snapshot_events.()
  end

  defp hydrate_state_for_sweep(state) do
    # Steady-state sweep failures must not kill already scheduled deadline timers.
    try do
      hydrate_state(state)
    rescue
      exception ->
        log_sweep_failed(:error, exception, __STACKTRACE__)
        state
    catch
      kind, reason ->
        log_sweep_failed(kind, reason, __STACKTRACE__)
        state
    end
  end

  defp schedule_or_run(state, channel, payload) do
    channel
    |> RuntimeEvents.expand(payload)
    |> Enum.reduce(state, fn %Event{} = event, acc ->
      case event.due_at do
        nil ->
          run_handler(acc, event)
          acc

        %DateTime{} = due_at ->
          schedule_at(acc, event, due_at)
      end
    end)
  end

  defp schedule_at(state, %Event{} = event, due_at) do
    now = DateTime.utc_now(:microsecond)

    case DateTime.compare(due_at, now) do
      :gt ->
        key = event.timer_key
        state = cancel_existing_timer(state, key)
        ref = make_ref()
        delay_ms = max(DateTime.diff(due_at, now, :millisecond), 0)
        timer = Process.send_after(self(), {:deadline, key, ref}, delay_ms)

        put_in(state, [:timers, key], %{
          ref: ref,
          timer: timer,
          event: event
        })

      _due ->
        run_handler(state, event)
        state
    end
  end

  defp cancel_existing_timer(state, key) do
    case Map.get(state.timers, key) do
      %{timer: timer} -> Process.cancel_timer(timer, async: true, info: false)
      _missing -> :ok
    end

    %{state | timers: Map.delete(state.timers, key)}
  end

  defp run_handler(state, %Event{} = event) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           Handlers.handle(event)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "runtime_events.scheduler.handler_start_failed",
          "runtime event handler start failed",
          %{
            channel: event.channel,
            reason: inspect(reason)
          }
        )
    end
  end

  defp sweep_interval_ms(opts) do
    value = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)

    case value do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 ->
        {:ok, interval_ms}

      invalid ->
        {:stop, {:invalid_sweep_interval_ms, invalid}}
    end
  end

  defp log_sweep_failed(kind, reason, stacktrace) do
    Logging.warning(
      "runtime_events.scheduler.sweep_failed",
      "runtime event scheduler sweep failed",
      %{
        reason: Exception.format(kind, reason, stacktrace)
      }
    )
  end
end
