defmodule BullXDiscord.Cache do
  @moduledoc false

  defstruct [:table]

  @type t :: %__MODULE__{table: :ets.tid()}

  @spec new() :: t()
  def new do
    %__MODULE__{table: :ets.new(__MODULE__, [:set, :private])}
  end

  @spec put(t(), atom(), term(), term(), non_neg_integer()) :: t()
  def put(%__MODULE__{table: table} = cache, namespace, key, value, ttl_ms)
      when is_atom(namespace) and is_integer(ttl_ms) and ttl_ms >= 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(table, {{namespace, key}, value, expires_at})
    cache
  end

  @spec fetch(t(), atom(), term()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{table: table}, namespace, key) do
    case :ets.lookup(table, {namespace, key}) do
      [{{^namespace, ^key}, value, expires_at}] ->
        fetch_fresh(table, {namespace, key}, value, expires_at)

      [] ->
        :error
    end
  end

  @spec put_direct_result(t(), String.t(), term(), non_neg_integer()) :: t()
  def put_direct_result(cache, event_id, result, ttl_ms),
    do: put(cache, :direct_command_result, event_id, result, ttl_ms)

  @spec fetch_direct_result(t(), String.t()) :: {:ok, term()} | :error
  def fetch_direct_result(cache, event_id), do: fetch(cache, :direct_command_result, event_id)

  @spec put_thread_ownership(t(), String.t(), String.t(), boolean(), non_neg_integer()) :: t()
  def put_thread_ownership(cache, channel_id, thread_channel_id, owned?, ttl_ms) do
    put(cache, :thread_ownership, {channel_id, thread_channel_id}, owned?, ttl_ms)
  end

  @spec fetch_thread_ownership(t(), String.t(), String.t()) :: {:ok, boolean()} | :error
  def fetch_thread_ownership(cache, channel_id, thread_channel_id) do
    fetch(cache, :thread_ownership, {channel_id, thread_channel_id})
  end

  @spec seen_direct_command?(t(), String.t(), non_neg_integer()) :: {boolean(), t()}
  def seen_direct_command?(cache, key, ttl_ms) do
    case fetch_direct_result(cache, key) do
      {:ok, _result} -> {true, cache}
      :error -> {false, put_direct_result(cache, key, true, ttl_ms)}
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
