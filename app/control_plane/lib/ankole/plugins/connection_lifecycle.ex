defmodule Ankole.Plugins.ConnectionLifecycle do
  @moduledoc false

  use GenServer

  @call_timeout 30_000

  @spec start_link(keyword(), keyword()) :: GenServer.on_start()
  def start_link(opts, config) when is_list(opts) and is_list(config) do
    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(
            :ankole,
            :signal_connection_reconcile_interval_ms,
            Keyword.fetch!(config, :default_interval_ms)
          )
        ),
      reconcile: Keyword.fetch!(config, :reconcile),
      reconcile_opts: Keyword.fetch!(config, :reconcile_opts)
    }

    GenServer.start_link(__MODULE__, state,
      name: Keyword.get(opts, :name, Keyword.fetch!(config, :name))
    )
  end

  @spec reconcile(GenServer.server()) :: term()
  def reconcile(server), do: GenServer.call(server, :reconcile, @call_timeout)

  @spec stop_undesired(map(), [term()], (term() -> :ok | {:error, term()})) :: non_neg_integer()
  def stop_undesired(specs, registered_keys, stop)
      when is_map(specs) and is_list(registered_keys) and is_function(stop, 1) do
    desired_keys = specs |> Map.keys() |> MapSet.new()

    registered_keys
    |> Enum.reject(&MapSet.member?(desired_keys, &1))
    |> Enum.count(&(stop.(&1) == :ok))
  end

  @impl true
  def init(state), do: {:ok, state, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, state) do
    run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  @impl true
  def handle_call(:reconcile, _from, state), do: {:reply, run_reconcile(state), state}

  @impl true
  def handle_info(:reconcile, state) do
    run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  defp run_reconcile(state), do: state.reconcile.(state.reconcile_opts)

  defp schedule_next(%{interval_ms: nil} = state), do: state

  defp schedule_next(%{interval_ms: interval_ms} = state) do
    Process.send_after(self(), :reconcile, interval_ms)
    state
  end
end
