defmodule BullX.IMGateway.DeliveryCircuitBreaker do
  @moduledoc false

  import BullX.Utils.Map, only: [maybe_put: 3]

  @table __MODULE__
  @default_failure_threshold 5
  @default_failure_window_ms 10_000
  @default_open_ms 30_000

  @type key :: {String.t(), String.t() | nil}

  @spec run(key(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run({adapter_id, _source_id} = key, fun, opts \\ [])
      when is_binary(adapter_id) and is_function(fun, 0) and is_list(opts) do
    ensure_table()

    now = now_ms()

    case gate_state(key, now, opts) do
      :open ->
        emit(:open, key, %{})
        {:error, open_error(key, opts)}

      state when state in [:closed, :half_open] ->
        fun.()
        |> tap(&record_result(key, state, &1, now, opts))
    end
  end

  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @spec reset(key()) :: :ok
  def reset(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  # Half-open is never written; it's derived from time-since-opened. Concurrent
  # probes can all see :half_open at once, but the first failure trips straight
  # back to :open (see record_failure/4 for :half_open).
  defp gate_state(key, now, opts) do
    case :ets.lookup(@table, key) do
      [{^key, %{status: :open, opened_at: opened_at}}] ->
        case now - opened_at >= open_ms(opts) do
          true -> :half_open
          false -> :open
        end

      _other ->
        :closed
    end
  end

  defp record_result(key, state, {:ok, _value}, _now, _opts) do
    reset(key)
    if state == :half_open, do: emit(:closed, key, %{})
  end

  defp record_result(key, state, {:error, reason}, now, opts) do
    record_failure(key, state, safe_error_kind(reason), now, opts)
  end

  defp record_result(_key, _state, _result, _now, _opts), do: :ok

  defp record_failure(key, :half_open, kind, now, _opts) do
    :ets.insert(@table, {key, %{status: :open, opened_at: now, failures: [now]}})
    emit(:opened, key, %{kind: kind})
  end

  defp record_failure(key, :closed, kind, now, opts) do
    failures =
      key
      |> failures_for()
      |> Enum.filter(&(now - &1 <= failure_window_ms(opts)))
      |> then(&[now | &1])

    case length(failures) >= failure_threshold(opts) do
      true ->
        :ets.insert(@table, {key, %{status: :open, opened_at: now, failures: failures}})
        emit(:opened, key, %{kind: kind})

      false ->
        :ets.insert(@table, {key, %{status: :closed, failures: failures}})
        emit(:failure, key, %{kind: kind, failure_count: length(failures)})
    end
  end

  defp failures_for(key) do
    case :ets.lookup(@table, key) do
      [{^key, %{failures: failures}}] when is_list(failures) -> failures
      _other -> []
    end
  end

  defp open_error({_adapter_id, source_id}, opts) do
    %{
      "kind" => "circuit_open",
      "message" => "Channel adapter delivery circuit is open.",
      "details" =>
        %{}
        |> maybe_put("source_id", source_id)
        |> maybe_put("retry_after_ms", open_ms(opts))
    }
  end

  defp safe_error_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp safe_error_kind(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp safe_error_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp safe_error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_kind(_reason), do: "unknown"

  defp failure_threshold(opts),
    do: integer_opt(opts, :failure_threshold, @default_failure_threshold)

  defp failure_window_ms(opts),
    do: integer_opt(opts, :failure_window_ms, @default_failure_window_ms)

  defp open_ms(opts), do: integer_opt(opts, :open_ms, @default_open_ms)

  defp integer_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @table
        end

      _info ->
        @table
    end
  end

  defp emit(event, {adapter_id, source_id}, metadata) do
    :telemetry.execute(
      [:bullx, :im_gateway, :adapter, :delivery_circuit, event],
      %{},
      metadata
      |> Map.put(:adapter_id, adapter_id)
      |> Map.put(:source_id, source_id)
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
