defmodule Ankole.AIGateway.ModelMetadata.Cache do
  @moduledoc """
  Small ETS-backed cache for provider-sourced model metadata.

  Only live provider sources use this cache. The packaged `llm_db` snapshot is
  already process-local and does not need another cache layer.
  """

  use GenServer

  @table __MODULE__

  @type lookup_result :: {:fresh, term()} | {:stale, term()} | :miss

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    _table =
      :ets.new(@table, [
        :named_table,
        :protected,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end

  @spec lookup(term()) :: lookup_result()
  def lookup(key) do
    with true <- table_exists?(),
         [{^key, value, expires_at_ms}] <- :ets.lookup(@table, key) do
      case monotonic_ms() < expires_at_ms do
        true -> {:fresh, value}
        false -> {:stale, value}
      end
    else
      _other -> :miss
    end
  end

  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms >= 0 do
    call({:put, key, value, ttl_ms})
  end

  @spec clear_for_test() :: :ok
  def clear_for_test do
    call(:clear)
  end

  @impl true
  def handle_call({:put, key, value, ttl_ms}, _from, state) do
    true = :ets.insert(@table, {key, value, monotonic_ms() + ttl_ms})
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _reason -> :ok
  end

  defp table_exists?, do: :ets.info(@table) != :undefined

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
