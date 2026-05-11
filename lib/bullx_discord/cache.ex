defmodule BullXDiscord.Cache do
  @moduledoc false

  alias BullXGateway.AdapterCache

  defstruct [:table]

  @type t :: %__MODULE__{table: :ets.tid()}

  @spec new() :: t()
  def new do
    %__MODULE__{table: AdapterCache.new(__MODULE__)}
  end

  @spec put(t(), atom(), term(), term(), non_neg_integer()) :: t()
  def put(%__MODULE__{table: table} = cache, namespace, key, value, ttl_ms)
      when is_atom(namespace) and is_integer(ttl_ms) and ttl_ms >= 0 do
    AdapterCache.put(table, namespace, key, value, ttl_ms)
    cache
  end

  @spec fetch(t(), atom(), term()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{table: table}, namespace, key) do
    AdapterCache.fetch(table, namespace, key)
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
end
