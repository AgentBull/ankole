defmodule BullX.Gateway.Outbound.Dispatcher do
  @moduledoc false

  use GenServer

  alias BullX.Gateway.Outbound.{ScopeSupervisor, Store}
  alias BullX.Repo

  @dispatch_channel "gateway_outbound_dispatches"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec notify() :: :ok
  def notify do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, :notify)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      poll_ms: Keyword.get(opts, :poll_ms, gateway_config(:outbound_dispatch_poll_ms, 1000)),
      batch_size:
        Keyword.get(opts, :batch_size, gateway_config(:outbound_dispatch_batch_size, 20)),
      stale_lock_ms:
        Keyword.get(
          opts,
          :stale_lock_ms,
          gateway_config(:outbound_dispatch_stale_lock_ms, 60_000)
        ),
      listener: nil,
      timer: nil
    }

    state =
      state
      |> maybe_start_listener(
        Keyword.get(opts, :listen?, gateway_config(:outbound_dispatch_listen?, true))
      )
      |> maybe_schedule_initial_scan()

    {:ok, state}
  end

  @impl true
  def handle_cast(:notify, state), do: {:noreply, schedule_scan(state, 0)}

  @impl true
  def handle_info({:notification, _pid, _ref, @dispatch_channel, payload}, state) do
    :telemetry.execute(
      [:bullx, :gateway, :dispatch_buffer, :notify],
      %{count: 1},
      %{channel: @dispatch_channel, payload: payload}
    )

    {:noreply, schedule_scan(state, 0)}
  end

  def handle_info(:scan, state) do
    state.batch_size
    |> Store.due_scopes(state.stale_lock_ms)
    |> Enum.each(&ScopeSupervisor.start_scope/1)

    {:noreply, schedule_scan(%{state | timer: nil}, state.poll_ms)}
  end

  def handle_info({:notification, _pid, _ref, _channel, _payload}, state), do: {:noreply, state}

  defp maybe_schedule_initial_scan(%{poll_ms: false} = state), do: state
  defp maybe_schedule_initial_scan(state), do: schedule_scan(state, 0)

  defp maybe_start_listener(state, false), do: state

  defp maybe_start_listener(state, true) do
    opts =
      Repo.config()
      |> Keyword.put(:auto_reconnect, true)

    case Postgrex.Notifications.start_link(opts) do
      {:ok, pid} ->
        case Postgrex.Notifications.listen(pid, @dispatch_channel) do
          {:ok, ref} -> %{state | listener: {pid, ref}}
          {:eventually, ref} -> %{state | listener: {pid, ref}}
        end

      {:error, _reason} ->
        state
    end
  rescue
    _exception -> state
  catch
    _kind, _reason -> state
  end

  defp schedule_scan(%{timer: nil} = state, false), do: state

  defp schedule_scan(%{timer: nil} = state, delay_ms) do
    %{state | timer: Process.send_after(self(), :scan, delay_ms)}
  end

  defp schedule_scan(state, _delay_ms), do: state

  defp gateway_config(key, default) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(key, default)
  end
end
