defmodule Ankole.Workflow.ConsoleQueries do
  @moduledoc "Read-only workflow diagnostics; run and call lifecycle owners remain unchanged."
  require Ash.Query
  alias Ankole.Workflow.Schemas.{AgentCall, Run}
  @live [:queued, :running, :sleeping]
  @terminal [:completed, :failed, :cancelled]

  def activity(agent_uid, calls_cursor, runs_cursor, limit) do
    calls = live_calls(agent_uid, calls_cursor, limit)
    runs = runs_without_live_calls_or_pending_cleanup(agent_uid, runs_cursor, limit)
    run_ids = Enum.uniq(Enum.map(calls.items, & &1.run_id) ++ Enum.map(runs.items, & &1.id))
    counts = Ankole.Workflow.Queries.run_counts(run_ids)

    %{
      live_calls:
        Enum.map(calls.items, fn call ->
          call
          |> call_projection()
          |> Map.put(:task_session_id, Ankole.Workflow.Queries.task_session_id(call.id))
          |> Map.put(:run_counts, Map.get(counts, call.run_id, empty_counts()))
        end),
      calls_next_cursor: calls.next_cursor,
      runs:
        Enum.map(runs.items, fn run ->
          run
          |> run_projection()
          |> Map.put(:counts, Map.get(counts, run.id, empty_counts()))
        end),
      runs_next_cursor: runs.next_cursor
    }
  end

  defp live_calls(agent_uid, cursor, limit) do
    AgentCall
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and run.agent_uid == ^agent_uid and status in ^@live
    )
    |> Ash.Query.load(:run)
    |> page(cursor, limit)
  end

  defp runs_without_live_calls_or_pending_cleanup(agent_uid, cursor, limit) do
    Run
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and
        ((status == :running and not exists(agent_calls, status in ^@live)) or
           (status in ^@terminal and is_nil(cleanup_completed_at)))
    )
    |> page(cursor, limit)
  end

  defp page(query, cursor, limit) do
    query = if cursor, do: Ash.Query.filter(query, id < ^cursor), else: query

    {:ok, rows} =
      query |> Ash.Query.sort(id: :desc) |> Ash.Query.limit(limit + 1) |> Ankole.Ash.read()

    items = Enum.take(rows, limit)
    %{items: items, next_cursor: if(length(rows) > limit, do: to_string(List.last(items).id))}
  end

  defp call_projection(%AgentCall{run: %Run{} = run} = call) do
    %{
      id: call.id,
      resource_kind: "workflow_call",
      run_id: run.id,
      agent_uid: call.agent_uid,
      run_status: Atom.to_string(run.status),
      run_title: run.title,
      owner_session_id: run.owner_session_id,
      label: call.label,
      status: Atom.to_string(call.status),
      sleep_note: call.sleep_note,
      wake_kind: if(call.wake_kind, do: Atom.to_string(call.wake_kind)),
      wake_at: call.wake_at,
      attention: call.attention,
      attempts: call.attempts,
      error_code: error_code(call.error),
      error_summary: error_summary(call.error),
      run_error_code: error_code(run.error),
      run_error_summary: error_summary(run.error),
      updated_at: call.updated_at
    }
  end

  defp run_projection(%Run{} = run) do
    %{
      id: run.id,
      resource_kind: "workflow_run",
      agent_uid: run.agent_uid,
      title: run.title,
      status: Atom.to_string(run.status),
      owner_session_id: run.owner_session_id,
      cleanup_pending: run.status != :running and is_nil(run.cleanup_completed_at),
      error_code: error_code(run.error),
      error_summary: error_summary(run.error),
      inserted_at: run.inserted_at,
      completed_at: run.completed_at,
      updated_at: run.updated_at
    }
  end

  # The projections give the text of a JSON member, as `->>` does, in at most
  # the given number of characters.
  defp error_code(error), do: error |> json_text("code") |> prefix(200)

  defp error_summary(error),
    do: (json_text(error, "summary") || json_text(error, "message")) |> prefix(1000)

  defp json_text(error, key) when is_map(error) do
    case Map.get(error, key) do
      nil -> nil
      value when is_binary(value) -> value
      value -> Ankole.JSON.encode!(value)
    end
  end

  defp json_text(_error, _key), do: nil

  defp prefix(nil, _length), do: nil
  defp prefix(text, length), do: text |> String.codepoints() |> Enum.take(length) |> Enum.join()

  defp empty_counts,
    do:
      Map.new(
        ["total", "queued", "running", "sleeping", "succeeded", "failed", "cancelled"],
        &{&1, 0}
      )
end
