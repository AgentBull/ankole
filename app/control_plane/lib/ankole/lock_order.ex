defmodule Ankole.LockOrder do
  @moduledoc "Checks the work lock order inside application transactions during tests."

  @enabled Application.compile_env(:ankole, :check_lock_order, false)
  @key {__MODULE__, :held}
  @identity {__MODULE__, :identity}

  def with_base_transaction(fun) do
    if @enabled, do: Process.put({__MODULE__, :base_transaction}, true)

    try do
      fun.()
    after
      if @enabled, do: Process.delete({__MODULE__, :base_transaction})
    end
  end

  def check_control_plane_lock! do
    if @enabled and Process.get({__MODULE__, :base_transaction}),
      do:
        raise(
          ArgumentError,
          "work lock order violation: control-plane lock after Base transaction at rank 12"
        )

    :ok
  end

  @doc """
  Gives a lock identity to the queries of a function.

  An Ash read cannot pass Ecto options to `Ankole.Repo`. `Ankole.Ash.read/2`
  uses this function so that `Repo.prepare_query/3` finds the identity.
  """
  def with_identity(identity, fun) when is_function(fun, 0) do
    previous = Process.put(@identity, identity)

    try do
      fun.()
    after
      if previous, do: Process.put(@identity, previous), else: Process.delete(@identity)
    end
  end

  @doc "Gives the explicit query identity, or the identity of the current Ash read."
  def identity(nil), do: Process.get(@identity)
  def identity(identity), do: identity

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
      "browser_sessions" => 1,
      "principals" => 3,
      "oidc_sessions" => 4,
      "agent_workers" => 5,
      "background_agent_jobs" => 7,
      "workflow_runs" => 7,
      "automation_jobs" => 7,
      "cron_schedules" => 7,
      "scheduled_events" => 8,
      "background_agent_job_turns" => 8,
      "workflow_agent_calls" => 8,
      "automation_job_runs" => 8,
      "sessions" => 10,
      "signals" => 11
    }
    # A trigger references its consumer. Lock the consumer before its cron rule,
    # including when both belong to the parent-work rank.
    @row_dependencies %{"automation_jobs" => "cron_schedules"}

    def check_query(%Ecto.Query{lock: nil}, _identity), do: :ok

    def check_query(%Ecto.Query{from: %{source: {table, _}}}, identity) do
      check_control_plane_lock!()

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
      do: check(9, {:session, agent_uid, session_id})

    def check_advisory(keys) when is_list(keys), do: Enum.each(keys, &check_advisory/1)

    def check_advisory(key) when is_binary(key) do
      check_control_plane_lock!()

      cond do
        String.starts_with?(key, "pod-tree:") -> check(2, {:pod_tree, key})
        String.contains?(key, ":running_slots:") -> check(6, {:slots, key})
        true -> :ok
      end
    end

    defp check(rank, lock) do
      check_control_plane_lock!()

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
