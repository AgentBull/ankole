defmodule Ankole.LockOrder do
  @moduledoc "Checks the work lock order inside application transactions during tests."

  @enabled Application.compile_env(:ankole, :check_lock_order, false)
  @key {__MODULE__, :held}

  def with_transaction(fun) when is_function(fun, 0) do
    if @enabled and is_nil(Process.get(@key)) do
      Process.put(@key, %{rank: 0, held: MapSet.new()})

      try do
        fun.()
      after
        Process.delete(@key)
      end
    else
      fun.()
    end
  end

  if @enabled do
    @row_ranks %{
      "principals" => 1,
      "agent_workers" => 2,
      "background_agent_jobs" => 4,
      "workflow_runs" => 4,
      "automation_jobs" => 4,
      "cron_schedules" => 4,
      "scheduled_events" => 5,
      "background_agent_job_turns" => 5,
      "workflow_agent_calls" => 5,
      "automation_job_runs" => 5,
      "sessions" => 7,
      "signals" => 8
    }
    # A trigger references its consumer. Lock the consumer before its cron rule,
    # including when both belong to the parent-work rank.
    @row_dependencies %{"automation_jobs" => "cron_schedules"}

    def check_query(%Ecto.Query{lock: nil}, _identity), do: :ok

    def check_query(%Ecto.Query{from: %{source: {table, _}}}, identity) do
      if Map.has_key?(@row_ranks, table) and Process.get(@key) do
        case identity do
          {:rows, ^table, key} when is_atom(key) -> :ok
          {^table, keys} -> check_rows(table, List.wrap(keys))
          _ -> raise ArgumentError, "locked #{table} query requires an explicit lock_identity"
        end
      end

      :ok
    end

    def check_query(_query, _identity), do: :ok

    def check_rows(table, []) do
      rank = Map.fetch!(@row_ranks, table)
      check(rank, {:row, table, :empty})
    end

    def check_rows(table, keys) do
      rank = Map.fetch!(@row_ranks, table)
      Enum.each(keys, &check(rank, {:row, table, &1}))
    end

    def check_advisory({agent_uid, session_id}),
      do: check(6, {:session, agent_uid, session_id})

    def check_advisory(key) when is_binary(key) do
      if String.contains?(key, ":running_slots:"), do: check(3, {:slots, key}), else: :ok
    end

    defp check(rank, lock) do
      case Process.get(@key) do
        %{rank: previous, held: held} = state ->
          unless MapSet.member?(held, lock) do
            if rank < previous do
              raise ArgumentError,
                    "work lock order violation: #{inspect(lock)} at rank #{rank} after rank #{previous}"
            end

            check_row_dependency!(lock, held)

            Process.put(@key, %{state | rank: rank, held: MapSet.put(held, lock)})
          end

          :ok

        nil ->
          :ok
      end
    end

    defp check_row_dependency!({:row, table, _} = lock, held) do
      case @row_dependencies[table] do
        nil ->
          :ok

        dependent ->
          if Enum.any?(held, &match?({:row, ^dependent, _}, &1)) do
            raise ArgumentError,
                  "work lock order violation: #{inspect(lock)} must precede #{dependent}"
          end
      end
    end

    defp check_row_dependency!(_lock, _held), do: :ok
  else
    def check_query(_query, _identity), do: :ok
    def check_rows(_table, _keys), do: :ok
    def check_advisory(_key), do: :ok
  end
end
