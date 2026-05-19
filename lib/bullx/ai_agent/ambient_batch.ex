defmodule BullX.AIAgent.AmbientBatch do
  @moduledoc """
  Weak Redis state for near-real-time ambient intervention checks.

  Loss of this state drops only one proactive opportunity; persisted ambient
  Messages remain durable context.
  """

  alias BullX.EventBus.StreamingOutput.Redis

  @ttl_ms 90_000
  @window_ms 30_000
  @freshness_ms 10_000

  @enqueue_lua """
  local meta = KEYS[1]
  local items = KEYS[2]
  local due = KEYS[3]
  local batch_key = ARGV[1]
  local meta_json = ARGV[2]
  local item_json = ARGV[3]
  local due_at = tonumber(ARGV[4])
  local ttl_ms = tonumber(ARGV[5])
  local now_ms = tonumber(ARGV[6])

  if redis.call('EXISTS', meta) ~= 0 then
    local existing = cjson.decode(redis.call('GET', meta))
    local existing_due_at = tonumber(existing['due_at'] or '0')

    if now_ms > existing_due_at then
      redis.call('DEL', meta, items)
      redis.call('ZREM', due, batch_key)
    end
  end

  if redis.call('EXISTS', meta) == 0 then
    redis.call('SET', meta, meta_json, 'PX', ttl_ms)
    redis.call('ZADD', due, due_at, batch_key)
  end

  redis.call('RPUSH', items, item_json)
  redis.call('PEXPIRE', items, ttl_ms)
  redis.call('PEXPIRE', meta, ttl_ms)
  return {'ok'}
  """

  @spec enqueue(map()) :: :ok | {:error, term()}
  def enqueue(%{} = batch) do
    now_ms = now_ms()
    due_at = now_ms + @window_ms
    batch_key = batch_key(batch.agent_principal_id, batch.ambient_conversation_id)

    meta =
      batch
      |> Map.take([:agent_principal_id, :ambient_conversation_id, :scene_key, :reply_channel])
      |> Map.merge(%{
        batch_key: batch_key,
        due_at: due_at,
        fresh_until: due_at + @freshness_ms,
        first_seen_at: now_ms
      })

    command = [
      "EVAL",
      @enqueue_lua,
      3,
      meta_key(batch_key),
      items_key(batch_key),
      due_key(),
      batch_key,
      Jason.encode!(stringify(meta)),
      Jason.encode!(stringify(batch.item)),
      due_at,
      @ttl_ms,
      now_ms
    ]

    case Redis.command(command) do
      {:ok, ["ok" | _]} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec due_batches() :: {:ok, [String.t()]} | {:error, term()}
  def due_batches do
    case Redis.command(["ZRANGEBYSCORE", due_key(), "-inf", now_ms(), "LIMIT", 0, 20]) do
      {:ok, keys} -> {:ok, keys}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec take(String.t()) :: {:ok, map(), [map()]} | :stale | :locked | {:error, term()}
  def take(batch_key) when is_binary(batch_key) do
    with :ok <- acquire_lock(batch_key),
         {:ok, meta_json} <- redis_get(meta_key(batch_key)),
         {:ok, item_jsons} <- Redis.command(["LRANGE", items_key(batch_key), 0, -1]),
         {:ok, meta} <- Jason.decode(meta_json),
         true <- fresh?(meta),
         {:ok, items} <- decode_items(item_jsons) do
      {:ok, meta, items}
    else
      false -> :stale
      :locked -> :locked
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_lock(batch_key) do
    case Redis.command(["SET", lock_key(batch_key), "1", "PX", @freshness_ms, "NX"]) do
      {:ok, "OK"} -> :ok
      {:ok, nil} -> :locked
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cleanup(String.t()) :: :ok
  def cleanup(batch_key) when is_binary(batch_key) do
    Redis.pipeline([
      ["DEL", meta_key(batch_key), items_key(batch_key), lock_key(batch_key)],
      ["ZREM", due_key(), batch_key]
    ])

    :ok
  end

  defp redis_get(key) do
    case Redis.command(["GET", key]) do
      {:ok, nil} -> {:error, :missing}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_items(item_jsons) do
    item_jsons
    |> Enum.reduce_while({:ok, []}, fn json, {:ok, acc} ->
      case Jason.decode(json) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp fresh?(%{"fresh_until" => fresh_until}) when is_integer(fresh_until),
    do: fresh_until >= now_ms()

  defp fresh?(_meta), do: false

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp batch_key(agent_principal_id, conversation_id),
    do: "#{agent_principal_id}:#{conversation_id}"

  defp meta_key(batch_key), do: "ai_agent:ambient_batch:#{batch_key}:meta"
  defp items_key(batch_key), do: "ai_agent:ambient_batch:#{batch_key}:items"
  defp lock_key(batch_key), do: "ai_agent:ambient_batch:#{batch_key}:lock"
  defp due_key, do: "ai_agent:ambient_batches:due"
  defp now_ms, do: System.system_time(:millisecond)
end
