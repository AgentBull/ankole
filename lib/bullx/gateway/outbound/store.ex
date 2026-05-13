defmodule BullX.Gateway.Outbound.Store do
  @moduledoc false

  alias BullX.Gateway.{Delivery, OutboundError}
  alias BullX.Repo

  @dispatch_channel "gateway_outbound_dispatches"
  @stream_channel "gateway_stream_chunks"

  @type scope :: %{adapter: String.t(), channel_id: String.t(), scope_id: String.t()}

  @spec accept_dispatch(Delivery.t()) ::
          {:ok, :inserted | :duplicate | :receipt_succeeded} | {:error, OutboundError.t()}
  def accept_dispatch(%Delivery{} = delivery) do
    result =
      Repo.transaction(fn ->
        case receipt_status(delivery.id, delivery.generation) do
          {:ok, "succeeded"} ->
            :receipt_succeeded

          {:ok, "dead_lettered"} ->
            Repo.rollback(:already_dead_lettered)

          :not_found ->
            insert_dispatch!(delivery)
        end
      end)

    normalize_accept_result(result)
  end

  @spec accept_stream(Delivery.t(), atom()) ::
          {:ok, :inserted | :duplicate | :receipt_succeeded, String.t()}
          | {:error, OutboundError.t()}
  def accept_stream(%Delivery{} = delivery, strategy)
      when strategy in [:native, :post_edit, :buffered] do
    stream_id = delivery.id

    result =
      Repo.transaction(fn ->
        case receipt_status(delivery.id, delivery.generation) do
          {:ok, "succeeded"} ->
            {:receipt_succeeded, stream_id}

          {:ok, "dead_lettered"} ->
            Repo.rollback(:already_dead_lettered)

          :not_found ->
            {insert_stream_session!(delivery, strategy, stream_id), stream_id}
        end
      end)

    case normalize_accept_result(result) do
      {:ok, status} -> {:ok, status, stream_id}
      {:error, error} -> {:error, error}
    end
  end

  @spec due_scopes(pos_integer(), non_neg_integer()) :: [scope()]
  def due_scopes(limit, stale_after_ms) when is_integer(limit) and limit > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_after_ms, :millisecond)

    query = """
    SELECT DISTINCT adapter, channel_id, scope_id
    FROM gateway_outbound_dispatches
    WHERE
      status = 'terminalizing'::gateway_outbound_status
      OR (status = 'pending'::gateway_outbound_status AND next_attempt_at <= now())
      OR (status = 'running'::gateway_outbound_status AND locked_at < $1)
    ORDER BY adapter, channel_id, scope_id
    LIMIT $2
    """

    case query(query, [cutoff, limit]) do
      {:ok, result} -> Enum.map(rows(result), &scope_from_row/1)
      {:error, _reason} -> []
    end
  end

  @spec terminalizing_streams(pos_integer()) :: [String.t()]
  def terminalizing_streams(limit) when is_integer(limit) and limit > 0 do
    query = """
    SELECT stream_id
    FROM gateway_stream_sessions
    WHERE status = 'terminalizing'::gateway_stream_status
      AND terminal_outcome IS NOT NULL
    ORDER BY updated_at ASC
    LIMIT $1
    """

    case query(query, [limit]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [stream_id] -> uuid_string(stream_id) end)
      {:error, _reason} -> []
    end
  end

  @spec terminalizing_for_scope(scope()) :: map() | nil
  def terminalizing_for_scope(scope) do
    query = """
    SELECT delivery_id, generation, op::text, status::text, adapter, channel_id, scope_id,
           delivery, terminal_outcome, attempts, next_attempt_at, locked_by, locked_at,
           inserted_at, updated_at
    FROM gateway_outbound_dispatches
    WHERE adapter = $1 AND channel_id = $2 AND scope_id = $3
      AND status = 'terminalizing'::gateway_outbound_status
      AND terminal_outcome IS NOT NULL
    ORDER BY updated_at ASC
    LIMIT 1
    """

    one(query, [scope.adapter, scope.channel_id, scope.scope_id])
  end

  @spec claim_due(scope(), String.t(), non_neg_integer()) :: map() | nil
  def claim_due(scope, worker_id, stale_after_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_after_ms, :millisecond)

    query = """
    WITH next AS (
      SELECT delivery_id, generation
      FROM gateway_outbound_dispatches
      WHERE adapter = $1 AND channel_id = $2 AND scope_id = $3
        AND (
          (status = 'pending'::gateway_outbound_status AND next_attempt_at <= now())
          OR (status = 'running'::gateway_outbound_status AND locked_at < $4)
        )
      ORDER BY next_attempt_at ASC, inserted_at ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE gateway_outbound_dispatches AS dispatch
    SET status = 'running'::gateway_outbound_status,
        locked_by = $5,
        locked_at = now(),
        attempts = dispatch.attempts + 1,
        updated_at = now()
    FROM next
    WHERE dispatch.delivery_id = next.delivery_id
      AND dispatch.generation = next.generation
    RETURNING dispatch.delivery_id, dispatch.generation, dispatch.op::text, dispatch.status::text,
              dispatch.adapter, dispatch.channel_id, dispatch.scope_id, dispatch.delivery,
              dispatch.terminal_outcome, dispatch.attempts, dispatch.next_attempt_at,
              dispatch.locked_by, dispatch.locked_at, dispatch.inserted_at, dispatch.updated_at
    """

    one(query, [scope.adapter, scope.channel_id, scope.scope_id, cutoff, worker_id])
  end

  @spec release_for_retry(map(), map(), non_neg_integer()) :: :ok | {:error, term()}
  def release_for_retry(row, _error, backoff_ms) do
    next_attempt_at = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

    query = """
    UPDATE gateway_outbound_dispatches
    SET status = 'pending'::gateway_outbound_status,
        terminal_outcome = NULL,
        next_attempt_at = $3,
        locked_by = NULL,
        locked_at = NULL,
        updated_at = now()
    WHERE delivery_id = $1 AND generation = $2
    """

    case query(query, [uuid(row["delivery_id"]), row["generation"], next_attempt_at]) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec capture_dispatch_terminal(map(), map()) :: :ok | {:error, term()}
  def capture_dispatch_terminal(row, terminal_outcome) do
    query = """
    UPDATE gateway_outbound_dispatches
    SET status = 'terminalizing'::gateway_outbound_status,
        terminal_outcome = $3::jsonb,
        locked_by = NULL,
        locked_at = NULL,
        updated_at = now()
    WHERE delivery_id = $1 AND generation = $2
    """

    case query(query, [uuid(row["delivery_id"]), row["generation"], terminal_outcome]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec append_stream_chunk(String.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def append_stream_chunk(stream_id, chunk, expires_at) when is_binary(stream_id) do
    result =
      Repo.transaction(fn ->
        seq = increment_stream_seq!(stream_id)
        insert_stream_chunk!(stream_id, seq, chunk, expires_at)
        notify!(@stream_channel, "#{stream_id}:#{seq}")
        :ok
      end)

    case result do
      {:ok, :ok} ->
        :telemetry.execute(
          [:bullx, :gateway, :stream_buffer, :append],
          %{count: 1},
          %{stream_id: stream_id}
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec capture_stream_terminal(String.t(), map()) :: :ok | {:error, term()}
  def capture_stream_terminal(stream_id, terminal_outcome) do
    query = """
    UPDATE gateway_stream_sessions
    SET status = 'terminalizing'::gateway_stream_status,
        terminal_outcome = $2::jsonb,
        updated_at = now()
    WHERE stream_id = $1
    """

    case query(query, [uuid(stream_id), terminal_outcome]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stream_session(String.t()) :: map() | nil
  def stream_session(stream_id) when is_binary(stream_id) do
    query = """
    SELECT stream_id, delivery_id, generation, adapter, channel_id, scope_id, strategy::text,
           status::text, last_seq, terminal_outcome, expires_at, inserted_at, updated_at
    FROM gateway_stream_sessions
    WHERE stream_id = $1
    """

    one(query, [uuid(stream_id)])
  end

  @spec stream_chunks(String.t(), non_neg_integer()) :: [map()]
  def stream_chunks(stream_id, after_seq) when is_binary(stream_id) and is_integer(after_seq) do
    query = """
    SELECT stream_id, seq, chunk, inserted_at, expires_at
    FROM gateway_stream_chunks
    WHERE stream_id = $1 AND seq > $2
    ORDER BY seq ASC
    """

    case query(query, [uuid(stream_id), after_seq]) do
      {:ok, result} ->
        chunks = rows(result)

        :telemetry.execute(
          [:bullx, :gateway, :stream_buffer, :resume],
          %{count: length(chunks)},
          %{stream_id: stream_id, after_seq: after_seq}
        )

        chunks

      {:error, _reason} ->
        []
    end
  end

  @spec expired_stream_cleanup(pos_integer()) :: non_neg_integer()
  def expired_stream_cleanup(limit) when is_integer(limit) and limit > 0 do
    query = """
    WITH expired_chunks AS (
      SELECT stream_id, seq
      FROM gateway_stream_chunks
      WHERE expires_at <= now()
      LIMIT $1
    ),
    deleted_chunks AS (
      DELETE FROM gateway_stream_chunks chunks
      USING expired_chunks
      WHERE chunks.stream_id = expired_chunks.stream_id AND chunks.seq = expired_chunks.seq
      RETURNING 1
    ),
    expired_sessions AS (
      SELECT stream_id
      FROM gateway_stream_sessions
      WHERE expires_at <= now()
        AND status IN ('succeeded'::gateway_stream_status, 'failed'::gateway_stream_status, 'cancelled'::gateway_stream_status)
      LIMIT $1
    ),
    deleted_sessions AS (
      DELETE FROM gateway_stream_sessions sessions
      USING expired_sessions
      WHERE sessions.stream_id = expired_sessions.stream_id
      RETURNING 1
    )
    SELECT
      (SELECT count(*) FROM deleted_chunks),
      (SELECT count(*) FROM deleted_sessions)
    """

    case query(query, [limit]) do
      {:ok, %{rows: [[chunks, sessions]]}} -> chunks + sessions
      _other -> 0
    end
  end

  @spec dead_letter(String.t()) :: map() | nil
  def dead_letter(id) when is_binary(id) do
    query = """
    SELECT id, delivery_id, adapter, channel_id, scope_id, thread_id, delivery,
           summary, last_error, attempts_total, replayable, replay_count,
           inserted_at, updated_at
    FROM gateway_dead_letters
    WHERE id = $1
    """

    one(query, [uuid(id)])
  end

  @spec increment_replay_count(String.t()) ::
          {:ok, non_neg_integer(), map()} | {:error, :not_found | :not_replayable | term()}
  def increment_replay_count(id) when is_binary(id) do
    result =
      Repo.transaction(fn ->
        case lock_dead_letter(id) do
          nil ->
            Repo.rollback(:not_found)

          %{"replayable" => false} ->
            Repo.rollback(:not_replayable)

          %{"replay_count" => count, "delivery" => delivery} ->
            new_count = count + 1
            update_dead_letter_replay_count!(id, new_count)
            {new_count, delivery}
        end
      end)

    case result do
      {:ok, {generation, delivery}} -> {:ok, generation, delivery}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finalize_dispatch(map(), Delivery.t(), map(), [term()]) :: :ok | {:error, term()}
  def finalize_dispatch(row, delivery, terminal_outcome, intents) do
    finalize(:dispatch, row, delivery, terminal_outcome, intents)
  end

  @spec finalize_stream(map(), Delivery.t(), map(), [term()]) :: :ok | {:error, term()}
  def finalize_stream(row, delivery, terminal_outcome, intents) do
    finalize(:stream, row, delivery, terminal_outcome, intents)
  end

  defp finalize(kind, row, delivery, %{"outcome" => outcome} = terminal_outcome, intents) do
    result =
      Ecto.Multi.new()
      |> maybe_dead_letter(delivery, terminal_outcome, row)
      |> Ecto.Multi.run(:receipt, fn repo, changes ->
        dead_letter_id = changes[:dead_letter_id]

        write_receipt(
          repo,
          delivery,
          outcome,
          terminal_outcome["outcome_signal_id"],
          dead_letter_id
        )
      end)
      |> BullX.Gateway.Mailbox.to_multi(:outcome_mailbox, intents)
      |> Ecto.Multi.run(:cleanup, fn repo, _changes ->
        cleanup_terminal(repo, kind, row, outcome)
      end)
      |> Repo.transaction()

    case result do
      {:ok, _changes} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp maybe_dead_letter(multi, _delivery, %{"outcome" => %{"status" => status}}, _row)
       when status in ["sent", "degraded"] do
    Ecto.Multi.run(multi, :dead_letter_id, fn _repo, _changes -> {:ok, nil} end)
  end

  defp maybe_dead_letter(multi, delivery, terminal_outcome, row) do
    Ecto.Multi.run(multi, :dead_letter_id, fn repo, _changes ->
      write_dead_letter(repo, delivery, terminal_outcome, row)
    end)
  end

  defp write_receipt(repo, delivery, outcome, outcome_signal_id, dead_letter_id) do
    terminal_status =
      case outcome["status"] do
        status when status in ["sent", "degraded"] -> "succeeded"
        "failed" -> "dead_lettered"
      end

    query = """
    INSERT INTO gateway_delivery_receipts
      (delivery_id, generation, adapter, channel_id, scope_id, terminal_status, outcome_signal_id, dead_letter_id, updated_at)
    VALUES
      ($1, $2, $3, $4, $5, $6::gateway_delivery_receipt_status, $7, $8, now())
    ON CONFLICT (delivery_id, generation)
    DO UPDATE SET
      adapter = EXCLUDED.adapter,
      channel_id = EXCLUDED.channel_id,
      scope_id = EXCLUDED.scope_id,
      terminal_status = EXCLUDED.terminal_status,
      outcome_signal_id = EXCLUDED.outcome_signal_id,
      dead_letter_id = EXCLUDED.dead_letter_id,
      updated_at = now()
    """

    case sql(repo, query, [
           uuid(delivery.id),
           delivery.generation,
           delivery.adapter,
           delivery.channel_id,
           delivery.scope_id,
           terminal_status,
           uuid(outcome_signal_id),
           nullable_uuid(dead_letter_id)
         ]) do
      {:ok, _result} -> {:ok, terminal_status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_dead_letter(repo, delivery, %{"outcome" => outcome} = terminal_outcome, row) do
    id = BullX.Ext.gen_uuid_v7()
    replayable? = delivery.op in [:send, :edit]
    delivery_snapshot = replayable_snapshot(delivery, replayable?)

    summary = %{
      "delivery_id" => delivery.id,
      "generation" => delivery.generation,
      "status" => outcome["status"],
      "adapter" => delivery.adapter,
      "channel_id" => delivery.channel_id,
      "scope_id" => delivery.scope_id,
      "stream_id" => row["stream_id"]
    }

    query = """
    INSERT INTO gateway_dead_letters
      (id, delivery_id, adapter, channel_id, scope_id, thread_id, delivery, summary,
       last_error, attempts_total, replayable, replay_count, inserted_at, updated_at)
    VALUES
      ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb, $9::jsonb, $10, $11, 0, now(), now())
    RETURNING id
    """

    case sql(repo, query, [
           uuid(id),
           uuid(delivery.id),
           delivery.adapter,
           delivery.channel_id,
           delivery.scope_id,
           delivery.thread_id,
           delivery_snapshot,
           summary,
           outcome["error"] || %{"kind" => "unknown"},
           terminal_outcome["attempts"] || 0,
           replayable?
         ]) do
      {:ok, %{rows: [[dead_letter_id]]}} ->
        case update_replayed_dead_letter_last_error(repo, delivery, outcome) do
          :ok -> {:ok, dead_letter_id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_replayed_dead_letter_last_error(repo, %Delivery{extensions: extensions}, outcome) do
    case Map.get(extensions, "replayed_dead_letter_id") do
      id when is_binary(id) ->
        query = """
        UPDATE gateway_dead_letters
        SET last_error = $2::jsonb,
            updated_at = now()
        WHERE id = $1
        """

        case sql(repo, query, [uuid(id), outcome["error"] || %{"kind" => "unknown"}]) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _other ->
        :ok
    end
  end

  defp replayable_snapshot(delivery, true), do: Delivery.dump(delivery)
  defp replayable_snapshot(_delivery, false), do: nil

  defp cleanup_terminal(repo, :dispatch, row, _outcome) do
    query = "DELETE FROM gateway_outbound_dispatches WHERE delivery_id = $1 AND generation = $2"

    case sql(repo, query, [uuid(row["delivery_id"]), row["generation"]]) do
      {:ok, _result} -> {:ok, :deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_terminal(repo, :stream, row, outcome) do
    status =
      case outcome["status"] do
        status when status in ["sent", "degraded"] -> "succeeded"
        "failed" -> "failed"
      end

    query = """
    UPDATE gateway_stream_sessions
    SET status = $2::gateway_stream_status,
        updated_at = now()
    WHERE stream_id = $1
    """

    case sql(repo, query, [uuid(row["stream_id"]), status]) do
      {:ok, _result} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receipt_status(delivery_id, generation) do
    query = """
    SELECT terminal_status::text
    FROM gateway_delivery_receipts
    WHERE delivery_id = $1 AND generation = $2
    """

    case query(query, [uuid(delivery_id), generation]) do
      {:ok, %{rows: [[status]]}} -> {:ok, status}
      {:ok, %{rows: []}} -> :not_found
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_dispatch!(%Delivery{} = delivery) do
    {:ok, snapshot} = Delivery.replay_snapshot(delivery)

    query = """
    INSERT INTO gateway_outbound_dispatches
      (delivery_id, generation, op, status, adapter, channel_id, scope_id, delivery,
       attempts, next_attempt_at, inserted_at, updated_at)
    VALUES
      ($1, $2, $3::gateway_outbound_op, 'pending'::gateway_outbound_status,
       $4, $5, $6, $7::jsonb, 0, now(), now(), now())
    ON CONFLICT (delivery_id, generation) DO NOTHING
    """

    case query(query, [
           uuid(delivery.id),
           delivery.generation,
           Atom.to_string(delivery.op),
           delivery.adapter,
           delivery.channel_id,
           delivery.scope_id,
           snapshot
         ]) do
      {:ok, %{num_rows: 1}} ->
        notify!(@dispatch_channel, "#{delivery.id}:#{delivery.generation}")
        :inserted

      {:ok, %{num_rows: 0}} ->
        :duplicate

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp insert_stream_session!(%Delivery{} = delivery, strategy, stream_id) do
    query = """
    INSERT INTO gateway_stream_sessions
      (stream_id, delivery_id, generation, adapter, channel_id, scope_id, strategy,
       status, last_seq, expires_at, inserted_at, updated_at)
    VALUES
      ($1, $2, $3, $4, $5, $6, $7::gateway_stream_strategy,
       'active'::gateway_stream_status, 0, $8, now(), now())
    ON CONFLICT (delivery_id, generation) DO NOTHING
    """

    expires_at = DateTime.add(DateTime.utc_now(), stream_ttl_seconds(), :second)

    case query(query, [
           uuid(stream_id),
           uuid(delivery.id),
           delivery.generation,
           delivery.adapter,
           delivery.channel_id,
           delivery.scope_id,
           Atom.to_string(strategy),
           expires_at
         ]) do
      {:ok, %{num_rows: 1}} -> :inserted
      {:ok, %{num_rows: 0}} -> :duplicate
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp increment_stream_seq!(stream_id) do
    query = """
    UPDATE gateway_stream_sessions
    SET last_seq = last_seq + 1,
        updated_at = now()
    WHERE stream_id = $1
    RETURNING last_seq
    """

    case query(query, [uuid(stream_id)]) do
      {:ok, %{rows: [[seq]]}} -> seq
      {:ok, %{rows: []}} -> Repo.rollback(:unknown_stream)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_stream_chunk!(stream_id, seq, chunk, expires_at) do
    query = """
    INSERT INTO gateway_stream_chunks
      (stream_id, seq, chunk, inserted_at, expires_at)
    VALUES
      ($1, $2, $3::jsonb, now(), $4)
    ON CONFLICT (stream_id, seq) DO NOTHING
    """

    case query(query, [uuid(stream_id), seq, chunk, expires_at]) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_dead_letter(id) do
    query = """
    SELECT id, delivery_id, adapter, channel_id, scope_id, thread_id, delivery,
           summary, last_error, attempts_total, replayable, replay_count,
           inserted_at, updated_at
    FROM gateway_dead_letters
    WHERE id = $1
    FOR UPDATE
    """

    case query(query, [uuid(id)]) do
      {:ok, result} -> rows(result) |> List.first()
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_dead_letter_replay_count!(id, replay_count) do
    query = """
    UPDATE gateway_dead_letters
    SET replay_count = $2,
        updated_at = now()
    WHERE id = $1
    """

    case query(query, [uuid(id), replay_count]) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp normalize_accept_result({:ok, {status, _stream_id}}), do: {:ok, status}
  defp normalize_accept_result({:ok, status}), do: {:ok, status}

  defp normalize_accept_result({:error, :already_dead_lettered}) do
    {:error,
     OutboundError.new(:already_dead_lettered, "delivery generation already dead-lettered")}
  end

  defp normalize_accept_result({:error, reason}) do
    {:error,
     OutboundError.new(:store_unavailable, "Gateway outbound dispatch store unavailable", %{
       reason: inspect(reason)
     })}
  end

  defp one(query, params) do
    case query(query, params) do
      {:ok, result} -> result |> rows() |> List.first()
      {:error, _reason} -> nil
    end
  end

  defp scope_from_row(%{"adapter" => adapter, "channel_id" => channel_id, "scope_id" => scope_id}) do
    %{adapter: adapter, channel_id: channel_id, scope_id: scope_id}
  end

  defp rows(%{columns: columns, rows: rows}) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp notify!(channel, payload) do
    case query("SELECT pg_notify($1, $2)", [channel, payload]) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp query(query, params), do: Ecto.Adapters.SQL.query(Repo, query, params)
  defp sql(repo, query, params), do: Ecto.Adapters.SQL.query(repo, query, params)

  defp nullable_uuid(nil), do: nil
  defp nullable_uuid(value), do: uuid(value)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        case Ecto.UUID.dump(uuid) do
          {:ok, dumped} -> dumped
          :error -> value
        end

      :error ->
        value
    end
  end

  defp uuid(value), do: value

  defp uuid_string(value) when is_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp uuid_string(value), do: value

  defp stream_ttl_seconds do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:stream_buffer_ttl_seconds, 86_400)
  end
end
