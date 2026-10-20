defmodule Ankole.AutomationJobs.ConsoleQueries do
  @moduledoc "Bounded reads of executing attempts, independently of definition status."
  import Ecto.Query
  alias Ankole.AutomationJobs.Schemas.{Job, Run}
  alias Ankole.Repo

  def activity(agent_uid, cursor, limit) do
    query =
      from(run in Run,
        join: job in Job,
        on: job.id == run.automation_job_id and job.tenant_id == run.tenant_id,
        where: job.agent_uid == ^agent_uid and run.status in ["queued", "running"],
        order_by: [desc: run.id],
        limit: ^(limit + 1),
        select: %{
          id: run.id,
          resource_kind: "automation_run",
          automation_job_id: job.id,
          agent_uid: job.agent_uid,
          label: job.label,
          owner_session_id: job.owner_session_id,
          definition_status: job.status,
          status: run.status,
          attempts: run.attempts,
          attempt_id: run.attempt_id,
          error: fragment("left(?, 1000)", run.error),
          scheduled_event_id: fragment("? #>> '{data,scheduled_event_id}'", run.event),
          started_at: run.started_at,
          inserted_at: run.inserted_at,
          updated_at: run.updated_at
        }
      )

    query = if cursor, do: where(query, [run], run.id < ^cursor), else: query
    rows = Repo.all(query)
    page = Enum.take(rows, limit)
    %{runs: page, next_cursor: if(length(rows) > limit, do: to_string(List.last(page).id))}
  end
end
