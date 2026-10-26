defmodule Ankole.Authn.RateLimiter do
  @moduledoc "Bounded node-local authentication windows. Challenge attempts remain durable."
  use GenServer
  alias Ankole.Authn.SecretDigest

  @table __MODULE__
  @max_keys 100_000
  @cleanup_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :cleanup, @cleanup_ms)
    {:ok, nil}
  end

  def take(limits), do: GenServer.call(__MODULE__, {:take, limits})
  def check(limits), do: limits |> windows() |> check_windows()

  defp windows(limits) do
    now = System.monotonic_time(:second)

    Enum.map(limits, fn {scope, target, limit, seconds} ->
      window = Integer.floor_div(now, seconds)
      key = {SecretDigest.digest("rate:" <> scope, to_string(target)), window, seconds}
      {key, limit, (window + 1) * seconds}
    end)
  end

  defp check_windows(windows) do
    Enum.reduce_while(windows, :ok, fn {key, limit, expires}, :ok ->
      count =
        case :ets.lookup(@table, key) do
          [{_, value, _}] -> value
          [] -> 0
        end

      if count >= limit,
        do: {:halt, {:error, {:rate_limited, max(1, expires - System.monotonic_time(:second))}}},
        else: {:cont, :ok}
    end)
  end

  @impl true
  def handle_call({:take, limits}, _from, state) do
    windows = windows(limits)

    result =
      with :ok <- check_windows(windows), :ok <- capacity(windows) do
        Enum.each(windows, fn {key, _, expires} ->
          :ets.update_counter(@table, key, {2, 1}, {key, 0, expires})
        end)

        :ok
      end

    {:reply, result, state}
  end

  defp capacity(windows) do
    new_keys = Enum.count(windows, fn {key, _, _} -> not :ets.member(@table, key) end)
    if :ets.info(@table, :size) + new_keys > @max_keys, do: expire_windows()

    if :ets.info(@table, :size) + new_keys <= @max_keys,
      do: :ok,
      else: {:error, {:rate_limited, 60}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    expire_windows()
    Process.send_after(self(), :cleanup, @cleanup_ms)
    {:noreply, state}
  end

  defp expire_windows do
    :ets.select_delete(@table, [
      {{:"$1", :"$2", :"$3"}, [{:"=<", :"$3", System.monotonic_time(:second)}], [true]}
    ])
  end

  if Mix.env() == :test do
    def reset_for_test, do: :ets.delete_all_objects(@table)
  end
end
