defmodule BullX.MailBox.Dispatcher do
  @moduledoc false

  use GenServer

  @interval_ms 500
  @retry_interval_ms 5_000
  @claim_limit 20

  @spec wake(non_neg_integer(), GenServer.server()) :: :ok
  def wake(delay_ms \\ 0, name \\ __MODULE__) when is_integer(delay_ms) and delay_ms >= 0 do
    case GenServer.whereis(name) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:wake, delay_ms})
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    claim_limit = Keyword.get(opts, :claim_limit, @claim_limit)

    state = %{
      interval_ms: interval_ms,
      claim_limit: claim_limit,
      timer_id: nil,
      timer_ref: nil
    }

    {:ok, schedule_dispatch(state, 0)}
  end

  @impl true
  def handle_cast({:wake, delay_ms}, state) when is_integer(delay_ms) and delay_ms >= 0 do
    {:noreply, schedule_earlier(state, delay_ms)}
  end

  @impl true
  def handle_info({:dispatch, timer_id}, %{timer_id: timer_id} = state) do
    run_dispatch(state)
  end

  def handle_info({:dispatch, _stale_timer_id}, state), do: {:noreply, state}

  defp run_dispatch(state) do
    state = %{state | timer_id: nil, timer_ref: nil}
    result = BullX.MailBox.process_ready(state.claim_limit)

    {:noreply, schedule_next_dispatch(state, result)}
  end

  defp schedule_next_dispatch(state, {:ok, count}) when count < state.claim_limit do
    case BullX.MailBox.next_ready_at() do
      nil -> state
      next_ready_at -> schedule_dispatch(state, delay_until(next_ready_at))
    end
  end

  defp schedule_next_dispatch(state, {:ok, _count}),
    do: schedule_dispatch(state, state.interval_ms)

  defp schedule_next_dispatch(state, {:error, _reason}),
    do: schedule_dispatch(state, @retry_interval_ms)

  defp schedule_earlier(%{timer_ref: nil} = state, delay_ms),
    do: schedule_dispatch(state, delay_ms)

  defp schedule_earlier(%{timer_ref: timer_ref} = state, delay_ms) do
    case Process.read_timer(timer_ref) do
      remaining_ms when is_integer(remaining_ms) and remaining_ms <= delay_ms ->
        state

      _remaining_ms ->
        state
        |> cancel_timer()
        |> schedule_dispatch(delay_ms)
    end
  end

  defp schedule_dispatch(state, delay_ms) do
    timer_id = make_ref()
    timer_ref = Process.send_after(self(), {:dispatch, timer_id}, delay_ms)

    %{state | timer_id: timer_id, timer_ref: timer_ref}
  end

  defp delay_until(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.diff(DateTime.utc_now(:microsecond), :millisecond)
    |> max(0)
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer_id: nil, timer_ref: nil}
  end
end
