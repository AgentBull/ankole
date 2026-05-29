defmodule BullX.MailBox.StreamingOutput do
  @moduledoc """
  Redis-backed weak MailBox session output stream buffer.
  """

  alias BullX.MailBox.Config
  alias BullX.Redis

  @open_status "open"
  @terminal_statuses [:completed, :failed, :interrupted]

  @append_lua """
  local meta = KEYS[1]
  local chunks = KEYS[2]
  local pub = KEYS[3]
  local stream_id = ARGV[1]
  local chunk = ARGV[2]
  local now_ms = ARGV[3]
  local ttl_ms = tonumber(ARGV[4])
  local max_bytes = tonumber(ARGV[5])

  if redis.call('EXISTS', meta) == 0 then
    return {'error', 'stream_not_found'}
  end

  if redis.call('HGET', meta, 'status') ~= 'open' then
    return {'error', 'stream_not_open'}
  end

  if string.len(chunk) > max_bytes then
    return {'error', 'chunk_too_large'}
  end

  local offset = tonumber(redis.call('HGET', meta, 'next_offset') or '0')
  redis.call('HSET', meta, 'next_offset', offset + 1, 'updated_at', now_ms, 'expires_at', now_ms + ttl_ms)
  redis.call('RPUSH', chunks, chunk)
  redis.call('PEXPIRE', meta, ttl_ms)
  redis.call('PEXPIRE', chunks, ttl_ms)
  redis.call('PUBLISH', pub, cjson.encode({stream_id = stream_id, offset = offset}))
  return {'ok', offset}
  """

  @finish_lua """
  local meta = KEYS[1]
  local chunks = KEYS[2]
  local pub = KEYS[3]
  local stream_id = ARGV[1]
  local status = ARGV[2]
  local reason = ARGV[3]
  local now_ms = ARGV[4]
  local ttl_ms = tonumber(ARGV[5])

  if redis.call('EXISTS', meta) == 0 then
    return {'error', 'stream_not_found'}
  end

  local existing = redis.call('HGET', meta, 'status')
  if existing == 'open' then
    redis.call('HSET', meta, 'status', status, 'terminal_reason', reason, 'updated_at', now_ms, 'expires_at', now_ms + ttl_ms)
    redis.call('PEXPIRE', meta, ttl_ms)
    redis.call('PEXPIRE', chunks, ttl_ms)
    redis.call('PUBLISH', pub, cjson.encode({stream_id = stream_id, status = status}))
    return {'ok'}
  end

  if existing == status and (redis.call('HGET', meta, 'terminal_reason') or '') == reason then
    return {'ok'}
  end

  return {'ok'}
  """

  @type stream_id :: String.t()
  @type stream_status :: :open | :completed | :failed | :interrupted

  @spec create_stream(String.t(), String.t() | nil, keyword()) ::
          {:ok, stream_id()} | {:error, :redis_unavailable | :invalid_opts}
  def create_stream(mailbox_session_id, mailbox_session_entry_id, opts \\ [])
      when is_binary(mailbox_session_id) and is_list(opts) do
    with :ok <- validate_opts(opts),
         stream_id <- BullX.Ext.gen_uuid_v7(),
         now <- now_ms(),
         ttl_ms <- ttl_ms(),
         meta <- meta_key(stream_id),
         fields <- metadata_fields(mailbox_session_id, mailbox_session_entry_id, now, ttl_ms),
         {:ok, _replies} <- Redis.pipeline([["HSET", meta | fields], ["PEXPIRE", meta, ttl_ms]]) do
      emit(:created, %{}, %{stream_id: stream_id, mailbox_session_id: mailbox_session_id})
      {:ok, stream_id}
    else
      {:error, :invalid_opts} -> {:error, :invalid_opts}
      {:error, _reason} -> {:error, :redis_unavailable}
    end
  end

  @spec append_chunk(stream_id(), String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :stream_not_found | :stream_not_open | :redis_unavailable | :chunk_too_large}
  def append_chunk(stream_id, chunk_text) when is_binary(stream_id) and is_binary(chunk_text) do
    case byte_size(chunk_text) <= Config.max_stream_chunk_bytes() do
      true -> do_append_chunk(stream_id, chunk_text)
      false -> {:error, :chunk_too_large}
    end
  end

  @spec finish_stream(stream_id(), :completed | :failed | :interrupted, String.t() | nil) ::
          :ok | {:error, :stream_not_found | :redis_unavailable}
  def finish_stream(stream_id, status, terminal_reason)
      when is_binary(stream_id) and status in @terminal_statuses do
    safe_reason = safe_terminal_reason(terminal_reason)

    command = [
      "EVAL",
      @finish_lua,
      3,
      meta_key(stream_id),
      chunks_key(stream_id),
      pub_key(stream_id),
      stream_id,
      Atom.to_string(status),
      safe_reason,
      now_ms(),
      ttl_ms()
    ]

    case Redis.command(command) do
      {:ok, ["ok" | _]} ->
        emit(status, %{}, %{stream_id: stream_id, stream_status: status})
        :ok

      {:ok, ["error", "stream_not_found"]} ->
        {:error, :stream_not_found}

      {:error, _reason} ->
        {:error, :redis_unavailable}
    end
  end

  @spec resume_stream(stream_id(), integer() | nil) ::
          {:ok,
           %{
             status: stream_status(),
             chunks: [%{offset: non_neg_integer(), chunk: String.t()}],
             follow?: boolean()
           }}
          | {:error, :unavailable | :no_content | :redis_unavailable}
  def resume_stream(stream_id, after_offset) when is_binary(stream_id) do
    start = normalize_after_offset(after_offset) + 1

    with {:ok, metadata} <- read_metadata(stream_id),
         {:ok, status} <- decode_resume_status(Map.fetch!(metadata, "status")),
         {:ok, chunks} <- read_chunks(stream_id, start) do
      follow? = status == :open

      {:ok, %{status: status, chunks: with_offsets(chunks, start), follow?: follow?}}
    end
  end

  @spec follow_stream(stream_id(), integer() | nil, (map() -> term())) ::
          :ok | {:error, :unavailable | :redis_unavailable}
  def follow_stream(stream_id, after_offset, consumer)
      when is_binary(stream_id) and is_function(consumer, 1) do
    with {:ok, resume} <- resume_stream(stream_id, after_offset),
         last_offset <- emit_chunks(resume.chunks, consumer, normalize_after_offset(after_offset)) do
      case resume.follow? do
        true -> follow_open_stream(stream_id, last_offset, consumer)
        false -> :ok
      end
    end
  end

  defp do_append_chunk(stream_id, chunk_text) do
    command = [
      "EVAL",
      @append_lua,
      3,
      meta_key(stream_id),
      chunks_key(stream_id),
      pub_key(stream_id),
      stream_id,
      chunk_text,
      now_ms(),
      ttl_ms(),
      Config.max_stream_chunk_bytes()
    ]

    case Redis.command(command) do
      {:ok, ["ok", offset]} ->
        offset = parse_offset(offset)

        emit(:chunk_appended, %{chunk_byte_size: byte_size(chunk_text)}, %{
          stream_id: stream_id,
          offset: offset
        })

        {:ok, offset}

      {:ok, ["error", reason]} ->
        {:error, String.to_existing_atom(reason)}

      {:error, _reason} ->
        {:error, :redis_unavailable}
    end
  end

  defp read_metadata(stream_id) do
    case Redis.command(["HGETALL", meta_key(stream_id)]) do
      {:ok, []} -> {:error, :unavailable}
      {:ok, values} -> {:ok, values_to_map(values)}
      {:error, _reason} -> {:error, :redis_unavailable}
    end
  end

  defp read_chunks(stream_id, start_offset) do
    case Redis.command(["LRANGE", chunks_key(stream_id), start_offset, -1]) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, _reason} -> {:error, :redis_unavailable}
    end
  end

  defp follow_open_stream(stream_id, last_offset, consumer) do
    with {:ok, opts} <- Redis.redix_options(),
         {:ok, pubsub} <- Redix.PubSub.start_link(opts),
         :ok <- subscribe(pubsub, pub_key(stream_id)) do
      case catch_up_after_subscribe(stream_id, last_offset, consumer) do
        {:ok, {:open, new_last_offset}} ->
          loop_follow(pubsub, stream_id, new_last_offset, consumer)

        {:ok, {:terminal, status}} ->
          consumer.(%{type: :terminal, status: status})
          Redix.PubSub.stop(pubsub)
          :ok

        {:error, reason} ->
          Redix.PubSub.stop(pubsub)
          {:error, reason}
      end
    else
      {:error, :invalid_redis_url} -> {:error, :redis_unavailable}
      {:error, _reason} -> {:error, :redis_unavailable}
    end
  end

  defp catch_up_after_subscribe(stream_id, last_offset, consumer) do
    with {:ok, chunks} <- read_chunks(stream_id, last_offset + 1),
         new_last_offset <-
           emit_chunks(with_offsets(chunks, last_offset + 1), consumer, last_offset),
         {:ok, metadata} <- read_metadata(stream_id),
         {:ok, status} <- decode_resume_status(Map.fetch!(metadata, "status")) do
      case status do
        :open -> {:ok, {:open, new_last_offset}}
        status -> {:ok, {:terminal, status}}
      end
    end
  end

  defp subscribe(pubsub, channel) do
    case Redix.PubSub.subscribe(pubsub, channel, self()) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp loop_follow(pubsub, stream_id, last_offset, consumer) do
    receive do
      {:redix_pubsub, ^pubsub, _ref, :message, %{payload: payload}} ->
        handle_pointer(pubsub, stream_id, last_offset, consumer, payload)

      {:redix_pubsub, ^pubsub, _ref, :disconnected, _properties} ->
        Redix.PubSub.stop(pubsub)
        {:error, :redis_unavailable}

      {:redix_pubsub, ^pubsub, _ref, :subscribed, _properties} ->
        loop_follow(pubsub, stream_id, last_offset, consumer)
    after
      Config.stream_retention_seconds() * 1_000 ->
        Redix.PubSub.stop(pubsub)
        :ok
    end
  end

  defp handle_pointer(pubsub, stream_id, last_offset, consumer, payload) do
    case Jason.decode(payload) do
      {:ok, %{"offset" => offset}} ->
        offset = parse_offset(offset)

        case read_chunk_range(stream_id, last_offset + 1, offset) do
          {:ok, chunks} ->
            new_last = emit_chunks(with_offsets(chunks, last_offset + 1), consumer, last_offset)
            loop_follow(pubsub, stream_id, new_last, consumer)

          {:error, _reason} ->
            Redix.PubSub.stop(pubsub)
            {:error, :redis_unavailable}
        end

      {:ok, %{"status" => status}} ->
        consumer.(%{type: :terminal, status: decode_status(status)})
        Redix.PubSub.stop(pubsub)
        :ok

      _other ->
        loop_follow(pubsub, stream_id, last_offset, consumer)
    end
  end

  defp read_chunk_range(stream_id, first, last) do
    case Redis.command(["LRANGE", chunks_key(stream_id), first, last]) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_chunks(chunks, consumer, last_offset) do
    Enum.reduce(chunks, last_offset, fn %{offset: offset, chunk: chunk}, _last ->
      consumer.(%{type: :chunk, offset: offset, chunk: chunk})
      offset
    end)
  end

  defp with_offsets(chunks, start_offset) do
    chunks
    |> Enum.with_index(start_offset)
    |> Enum.map(fn {chunk, offset} -> %{offset: offset, chunk: chunk} end)
  end

  defp metadata_fields(mailbox_session_id, mailbox_session_entry_id, now, ttl_ms) do
    [
      "status",
      @open_status,
      "next_offset",
      0,
      "mailbox_session_id",
      mailbox_session_id,
      "mailbox_session_entry_id",
      mailbox_session_entry_id || "",
      "created_at",
      now,
      "updated_at",
      now,
      "expires_at",
      now + ttl_ms,
      "terminal_reason",
      ""
    ]
  end

  defp validate_opts(opts) do
    case Keyword.keys(opts) -- [:format, :diagnostic_code] do
      [] -> :ok
      _unsupported -> {:error, :invalid_opts}
    end
  end

  defp values_to_map(values) do
    values
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {key, value} end)
  end

  defp normalize_after_offset(nil), do: -1
  defp normalize_after_offset(offset) when is_integer(offset), do: offset

  defp parse_offset(offset) when is_integer(offset), do: offset
  defp parse_offset(offset) when is_binary(offset), do: String.to_integer(offset)

  defp decode_status("open"), do: :open
  defp decode_status("completed"), do: :completed
  defp decode_status("failed"), do: :failed
  defp decode_status("interrupted"), do: :interrupted
  defp decode_status(_status), do: :interrupted

  defp decode_resume_status("expired"), do: {:error, :unavailable}
  defp decode_resume_status("open"), do: {:ok, :open}
  defp decode_resume_status("completed"), do: {:ok, :completed}
  defp decode_resume_status("failed"), do: {:ok, :failed}
  defp decode_resume_status("interrupted"), do: {:ok, :interrupted}
  defp decode_resume_status(_status), do: {:error, :unavailable}

  defp ttl_ms, do: Config.stream_retention_seconds() * 1_000
  defp now_ms, do: System.system_time(:millisecond)

  defp meta_key(stream_id), do: "bullx:stream:#{stream_id}:meta"
  defp chunks_key(stream_id), do: "bullx:stream:#{stream_id}:chunks"
  defp pub_key(stream_id), do: "bullx:stream:#{stream_id}:pub"

  defp safe_terminal_reason(nil), do: ""
  defp safe_terminal_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_terminal_reason(reason) when is_binary(reason) do
    case String.valid?(reason) do
      true -> reason
      false -> inspect(reason, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp safe_terminal_reason(reason),
    do: inspect(reason, limit: :infinity, printable_limit: :infinity)

  defp emit(event, measurements, metadata) do
    :telemetry.execute([:bullx, :mail_box, :stream, event], measurements, metadata)
  end
end
