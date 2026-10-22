defmodule Ankole.Workflow.ConsoleQueries do
  @moduledoc "Read-only workflow diagnostics; run and call lifecycle owners remain unchanged."
  import Ecto.Query
  alias Ankole.Repo
  alias Ankole.Workflow.Schemas.{AgentCall, Run}
  @live [:queued, :running, :sleeping]

  def activity(agent_uid, calls_cursor, runs_cursor, limit) do
    calls = live_calls(agent_uid, calls_cursor, limit)
    runs = runs_without_live_calls_or_pending_cleanup(agent_uid, runs_cursor, limit)
    run_ids = Enum.uniq(Enum.map(calls.items, & &1.run_id) ++ Enum.map(runs.items, & &1.id))
    counts = counts(run_ids)

    %{
      live_calls:
        Enum.map(calls.items, fn call ->
          call
          |> Map.put(:status, Atom.to_string(call.status))
          |> Map.put(:wake_kind, if(call.wake_kind, do: Atom.to_string(call.wake_kind)))
          |> Map.put(:run_status, Atom.to_string(call.run_status))
          |> Map.put(:task_session_id, Ankole.Workflow.Queries.task_session_id(call.id))
          |> Map.put(:run_counts, Map.get(counts, call.run_id, empty_counts()))
        end),
      calls_next_cursor: calls.next_cursor,
      runs:
        Enum.map(runs.items, fn run ->
          run
          |> Map.put(:status, Atom.to_string(run.status))
          |> Map.put(:counts, Map.get(counts, run.id, empty_counts()))
        end),
      runs_next_cursor: runs.next_cursor
    }
  end

  defp live_calls(agent_uid, cursor, limit) do
    from(call in AgentCall,
      join: run in Run,
      on: run.id == call.run_id and run.tenant_id == call.tenant_id,
      where:
        call.agent_uid == ^agent_uid and run.agent_uid == ^agent_uid and call.status in @live,
      select: %{
        id: call.id,
        resource_kind: "workflow_call",
        run_id: run.id,
        agent_uid: call.agent_uid,
        run_status: run.status,
        run_title: run.title,
        owner_session_id: run.owner_session_id,
        label: call.label,
        status: call.status,
        sleep_note: call.sleep_note,
        wake_kind: call.wake_kind,
        wake_at: call.wake_at,
        attention: call.attention,
        attempts: call.attempts,
        error_code: fragment("left(?->>'code', 200)", call.error),
        error_summary:
          fragment("left(COALESCE(?->>'summary', ?->>'message'), 1000)", call.error, call.error),
        run_error_code: fragment("left(?->>'code', 200)", run.error),
        run_error_summary:
          fragment("left(COALESCE(?->>'summary', ?->>'message'), 1000)", run.error, run.error),
        updated_at: call.updated_at
      }
    )
    |> page(cursor, limit)
  end

  defp runs_without_live_calls_or_pending_cleanup(agent_uid, cursor, limit) do
    live =
      from(call in AgentCall,
        where: call.run_id == parent_as(:run).id and call.tenant_id == parent_as(:run).tenant_id,
        where: call.status in @live,
        select: 1
      )

    from(run in Run,
      as: :run,
      where: run.agent_uid == ^agent_uid,
      where:
        (run.status == :running and not exists(subquery(live))) or
          (run.status in [:completed, :failed, :cancelled] and is_nil(run.cleanup_completed_at)),
      select: %{
        id: run.id,
        resource_kind: "workflow_run",
        agent_uid: run.agent_uid,
        title: run.title,
        status: run.status,
        owner_session_id: run.owner_session_id,
        cleanup_pending: run.status != :running and is_nil(run.cleanup_completed_at),
        error_code: fragment("left(?->>'code', 200)", run.error),
        error_summary:
          fragment("left(COALESCE(?->>'summary', ?->>'message'), 1000)", run.error, run.error),
        inserted_at: run.inserted_at,
        completed_at: run.completed_at,
        updated_at: run.updated_at
      }
    )
    |> page(cursor, limit)
  end

  defp page(query, cursor, limit) do
    query = if cursor, do: where(query, [row], row.id < ^cursor), else: query
    rows = query |> order_by([row], desc: row.id) |> limit(^(limit + 1)) |> Repo.all()
    items = Enum.take(rows, limit)
    %{items: items, next_cursor: if(length(rows) > limit, do: to_string(List.last(items).id))}
  end

  defp counts([]), do: %{}

  defp counts(ids) do
    from(call in AgentCall,
      where: call.run_id in ^ids,
      group_by: [call.run_id, call.status],
      select: {call.run_id, call.status, count(call.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, status, count}, acc ->
      status = Atom.to_string(status)
      Map.update(acc, id, Map.put(empty_counts(), status, count), &Map.put(&1, status, count))
    end)
    |> Map.new(fn {id, counts} ->
      {id, Map.put(counts, "total", Enum.sum(Map.values(counts)))}
    end)
  end

  defp empty_counts,
    do:
      Map.new(
        ["total", "queued", "running", "sleeping", "succeeded", "failed", "cancelled"],
        &{&1, 0}
      )
end
