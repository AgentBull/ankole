defmodule Ankole.AutomationJobs.ConsoleQueries do
  @moduledoc "Bounded reads of executing attempts, independently of definition status."
  require Ash.Query
  alias Ankole.AutomationJobs.Schemas.Run

  def activity(agent_uid, cursor, limit) do
    query =
      Run
      |> Ash.Query.filter(job.agent_uid == ^agent_uid and status in [:queued, :running])
      |> Ash.Query.load([:job_agent_uid, :job_label, :job_owner_session_id, :job_status])

    query = if cursor, do: Ash.Query.filter(query, id < ^cursor), else: query

    {:ok, page} =
      query
      |> Ash.Query.sort(id: :desc)
      |> Ankole.Ash.read(action: :list_page, page: [limit: limit])

    %{
      runs: Enum.map(page.results, &projection/1),
      next_cursor: if(page.more?, do: to_string(List.last(page.results).id))
    }
  end

  defp projection(%Run{} = run) do
    %{
      id: run.id,
      resource_kind: "automation_run",
      automation_job_id: run.automation_job_id,
      agent_uid: run.job_agent_uid,
      label: run.job_label,
      owner_session_id: run.job_owner_session_id,
      definition_status: run.job_status,
      status: run.status,
      attempts: run.attempts,
      attempt_id: run.attempt_id,
      error: prefix(run.error, 1000),
      scheduled_event_id: scheduled_event_id(run.event),
      started_at: run.started_at,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  # The text of `event.data.scheduled_event_id`, as the `#>>` operator gives it.
  defp scheduled_event_id(%{"data" => %{"scheduled_event_id" => id}}) when is_binary(id), do: id

  defp scheduled_event_id(%{"data" => %{"scheduled_event_id" => id}}) when not is_nil(id),
    do: Ankole.JSON.encode!(id)

  defp scheduled_event_id(_event), do: nil

  defp prefix(nil, _length), do: nil
  defp prefix(text, length), do: text |> String.codepoints() |> Enum.take(length) |> Enum.join()
end
