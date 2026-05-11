defmodule BullXGateway.AdapterCache do
  @moduledoc """
  Process-local TTL cache helper for Gateway adapters.

  Adapter caches are discardable accelerators owned by adapter processes. They
  must not become durable truth; restart recovery comes from the external
  platform plus Gateway/Runtime persistence.
  """

  @type table :: :ets.tid()

  @spec new(atom()) :: table()
  def new(owner) when is_atom(owner) do
    :ets.new(owner, [:set, :private])
  end

  @spec put(table(), atom(), term(), term(), non_neg_integer()) :: :ok
  def put(table, namespace, key, value, ttl_ms)
      when is_atom(namespace) and is_integer(ttl_ms) and ttl_ms >= 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(table, {{namespace, key}, value, expires_at})
    :ok
  end

  @spec fetch(table(), atom(), term()) :: {:ok, term()} | :error
  def fetch(table, namespace, key) when is_atom(namespace) do
    case :ets.lookup(table, {namespace, key}) do
      [{{^namespace, ^key}, value, expires_at}] ->
        fetch_fresh(table, {namespace, key}, value, expires_at)

      [] ->
        :error
    end
  end

  defp fetch_fresh(table, key, value, expires_at) do
    case expires_at >= System.monotonic_time(:millisecond) do
      true ->
        {:ok, value}

      false ->
        :ets.delete(table, key)
        :error
    end
  end
end
