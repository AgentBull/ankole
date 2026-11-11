defmodule Ankole.Pod.Spreadsheets.NodeCache do
  @moduledoc """
  Keeps recently used spreadsheet documents open on this node.

  An entry maps `{tenant_id, page_id}` to the kernel document at one committed
  revision. The cache holds at most 64 documents, drops the least recently
  used one beyond that, and drops a document that nobody used for ten
  minutes. It never owns state: a caller that misses reopens the page file and
  replays its uncompacted operations, and a caller that finds an older
  revision replays the operations committed since.
  """
  use GenServer

  @table __MODULE__
  @max_documents 64
  @idle_ms :timer.minutes(10)
  @sweep_ms :timer.minutes(1)
  @touch_ms :timer.seconds(30)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the cached document and its revision, or `:error`."
  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, revision, doc, used}] ->
        now = now()
        # Idle eviction and LRU order need only coarse recency, so reads skip most ETS writes.
        if now - used > @touch_ms, do: :ets.update_element(@table, key, {4, now})
        {:ok, revision, doc}

      [] ->
        :error
    end
  end

  @doc "Caches a document unless the cache already holds a later revision of it."
  def put(key, revision, doc), do: GenServer.call(__MODULE__, {:put, key, revision, doc})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, key, revision, doc}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, cached, _doc, _used}] when cached > revision ->
        :ok

      _entry ->
        :ets.insert(@table, {key, revision, doc, now()})
        if :ets.info(@table, :size) > @max_documents, do: evict_least_recent()
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - @idle_ms
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp evict_least_recent do
    {key, _used} =
      :ets.foldl(
        fn {key, _revision, _doc, used}, oldest ->
          if oldest == nil or used < elem(oldest, 1), do: {key, used}, else: oldest
        end,
        nil,
        @table
      )

    :ets.delete(@table, key)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
