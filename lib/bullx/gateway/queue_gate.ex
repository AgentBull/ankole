defmodule BullX.Gateway.QueueGate do
  @moduledoc """
  Reconstructible Gateway mailbox queue readiness gate.

  Gateway can boot before Runtime is ready. This process keeps Gateway-owned
  Oban queues paused until Runtime and the configured consumer delivery boundary
  are available, then resumes them locally. Queue state is reconstructible from
  application config on restart; this process does not own durable truth.
  """

  use GenServer

  @default_poll_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec ready?() :: boolean()
  def ready? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      _pid -> GenServer.call(__MODULE__, :ready?)
    end
  end

  @spec refresh() :: :ok
  def refresh do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, :refresh)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      queues: Keyword.get(opts, :queues, gateway_config(:mailbox_queues, ["gateway_signals"])),
      poll_ms: Keyword.get(opts, :poll_ms, gateway_config(:queue_gate_poll_ms, @default_poll_ms)),
      ready?: false,
      timer: nil
    }

    pause_queues(state.queues)

    {:ok, schedule_refresh(state, 0)}
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, refresh_state(%{state | timer: nil})}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, refresh_state(%{state | timer: nil})}

  defp refresh_state(state) do
    ready? = runtime_ready?() and consumer_ready?()

    case {state.ready?, ready?} do
      {false, true} -> resume_queues(state.queues)
      {true, false} -> pause_queues(state.queues)
      _same -> :ok
    end

    state
    |> Map.put(:ready?, ready?)
    |> schedule_refresh(state.poll_ms)
  end

  defp runtime_ready?, do: Process.whereis(BullX.Runtime.Supervisor) != nil

  defp consumer_ready? do
    module = gateway_config(:consumer_delivery, BullX.Gateway.ConsumerDelivery.Unavailable)

    cond do
      module == BullX.Gateway.ConsumerDelivery.Unavailable ->
        false

      is_atom(module) and function_exported?(module, :ready?, 0) ->
        safe_ready?(module)

      is_atom(module) and function_exported?(module, :deliver, 1) ->
        true

      true ->
        false
    end
  end

  defp safe_ready?(module) do
    case module.ready?() do
      true -> true
      _other -> false
    end
  catch
    _kind, _reason -> false
  end

  defp pause_queues(queues), do: Enum.each(queues, &queue_signal(&1, :pause))
  defp resume_queues(queues), do: Enum.each(queues, &queue_signal(&1, :resume))

  defp queue_signal(queue, action) when is_binary(queue) do
    queue
    |> String.to_atom()
    |> queue_signal(action)
  end

  defp queue_signal(queue, action) when is_atom(queue) do
    result =
      case action do
        :pause -> Oban.pause_queue(queue: queue)
        :resume -> Oban.resume_queue(queue: queue)
      end

    case result do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp schedule_refresh(state, false), do: state

  defp schedule_refresh(%{timer: nil} = state, delay_ms) do
    %{state | timer: Process.send_after(self(), :refresh, delay_ms)}
  end

  defp schedule_refresh(state, _delay_ms), do: state

  defp gateway_config(key, default) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(key, default)
  end
end
