defmodule BullX.BusSpy do
  @moduledoc false

  use GenServer

  @default_events [
    [:bullx, :event_bus, :accepted],
    [:bullx, :event_bus, :accepted_ignored],
    [:bullx, :event_bus, :rule_matched],
    [:bullx, :event_bus, :adapter, :delivery_circuit, :failure],
    [:bullx, :event_bus, :adapter, :delivery_circuit, :opened],
    [:bullx, :event_bus, :adapter, :delivery_circuit, :open],
    [:bullx, :event_bus, :adapter, :delivery_circuit, :closed],
    [:bullx, :ai_agent, :acl_denied]
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec clear_events(GenServer.server()) :: :ok
  def clear_events(server), do: GenServer.call(server, :clear_events)

  @spec events(GenServer.server()) :: [map()]
  def events(server), do: GenServer.call(server, :events)

  @spec get_events_by_type(GenServer.server(), [atom()]) :: [map()]
  def get_events_by_type(server, pattern) when is_list(pattern) do
    server
    |> events()
    |> Enum.filter(&event_matches?(&1.event, pattern))
  end

  @spec wait_for_event(GenServer.server(), [atom()], non_neg_integer()) :: {:ok, map()} | :timeout
  def wait_for_event(server, pattern, timeout_ms \\ 1_000)
      when is_list(pattern) and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_event(server, pattern, deadline)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    events = Keyword.get(opts, :events, @default_events)
    handler_id = {__MODULE__, self(), make_ref()}

    :telemetry.attach_many(
      handler_id,
      events,
      &__MODULE__.handle_telemetry/4,
      self()
    )

    {:ok, %{events: [], handler_id: handler_id}}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  @impl true
  def handle_call(:clear_events, _from, state), do: {:reply, :ok, %{state | events: []}}
  def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

  @impl true
  def handle_cast({:event, event}, state),
    do: {:noreply, %{state | events: [event | state.events]}}

  def handle_telemetry(event, measurements, metadata, server) do
    GenServer.cast(server, {
      :event,
      %{
        event: event,
        measurements: measurements,
        metadata: metadata,
        observed_at_ms: System.system_time(:millisecond)
      }
    })
  end

  defp do_wait_for_event(server, pattern, deadline) do
    case List.first(get_events_by_type(server, pattern)) do
      nil ->
        case System.monotonic_time(:millisecond) >= deadline do
          true ->
            :timeout

          false ->
            Process.sleep(10)
            do_wait_for_event(server, pattern, deadline)
        end

      event ->
        {:ok, event}
    end
  end

  defp event_matches?(event, pattern) do
    length(event) == length(pattern) and
      event
      |> Enum.zip(pattern)
      |> Enum.all?(fn
        {_event_part, :_} -> true
        {part, part} -> true
        _other -> false
      end)
  end
end
