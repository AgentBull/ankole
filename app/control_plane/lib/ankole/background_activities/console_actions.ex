defmodule Ankole.BackgroundActivities.ConsoleActions do
  @moduledoc "Reads live Jobs, Workflow activity, and Automation runs independently."
  use Ash.Resource.Actions.Implementation
  alias Ankole.Errors
  @impl true
  def run(input, _opts, _context) do
    result =
      with {:ok, uid} <- Ankole.Principals.normalize_uid(input.arguments.agent_uid),
           do: execute(input, uid)

    Errors.wrap(result, &describe/1)
  end

  defp execute(%{action: %{name: :console_jobs}, arguments: attrs}, uid) do
    with {:ok, page} <-
           Ankole.BackgroundAgentJobs.Queries.list_activity(uid,
             cursor: Map.get(attrs, :cursor),
             limit: attrs.limit
           ),
         do: {:ok, page(page, [:jobs])}
  end

  defp execute(%{action: %{name: :console_automation_runs}, arguments: attrs}, uid) do
    with {:ok, cursor} <- cursor(Map.get(attrs, :cursor)) do
      {:ok,
       page(Ankole.AutomationJobs.ConsoleQueries.activity(uid, cursor, attrs.limit), [:runs])}
    end
  end

  defp execute(%{action: %{name: :console_workflow}, arguments: attrs}, uid) do
    with {:ok, calls} <- cursor(Map.get(attrs, :calls_cursor)),
         {:ok, runs} <- cursor(Map.get(attrs, :runs_cursor)) do
      {:ok,
       page(Ankole.Workflow.ConsoleQueries.activity(uid, calls, runs, attrs.limit), [
         :live_calls,
         :runs
       ])}
    end
  end

  defp page(page, groups) do
    Enum.reduce(
      groups,
      Map.put(page, :observed_at, DateTime.to_iso8601(DateTime.utc_now(:microsecond))),
      fn group, page ->
        Map.update!(page, group, fn rows -> Enum.map(rows, &Ankole.JSON.plain/1) end)
      end
    )
  end

  defp cursor(value) when value in [nil, ""], do: {:ok, nil}

  defp cursor(value) when is_binary(value) do
    case Ankole.ModelIntegerID.parse(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_activity_cursor}
    end
  end

  defp describe(_), do: {"The Agent or activity cursor is invalid", []}
end
