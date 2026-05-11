defmodule BullXFeishu.Cache do
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

  @spec put_message_context(t(), String.t(), map(), non_neg_integer()) :: t()
  def put_message_context(cache, message_id, context, ttl_ms),
    do: put(cache, :message_context, message_id, context, ttl_ms)

  @spec fetch_message_context(t(), String.t()) :: {:ok, map()} | :error
  def fetch_message_context(cache, message_id), do: fetch(cache, :message_context, message_id)

  @spec put_direct_result(t(), String.t(), term(), non_neg_integer()) :: t()
  def put_direct_result(cache, event_id, result, ttl_ms),
    do: put(cache, :direct_command_result, event_id, result, ttl_ms)

  @spec fetch_direct_result(t(), String.t()) :: {:ok, term()} | :error
  def fetch_direct_result(cache, event_id), do: fetch(cache, :direct_command_result, event_id)

  @spec seen_card_action?(t(), String.t(), non_neg_integer()) :: {boolean(), t()}
  def seen_card_action?(cache, key, ttl_ms) do
    case fetch(cache, :card_action_dedupe, key) do
      {:ok, true} -> {true, cache}
      :error -> {false, put(cache, :card_action_dedupe, key, true, ttl_ms)}
    end
  end
end
