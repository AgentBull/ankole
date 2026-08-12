defmodule Ankole.BackgroundAgentJobs.Health do
  @moduledoc """
  Operator-facing reliability metrics for BackgroundAgentJobs.

  Four signals cover the failure modes the 2026-08-12 incident exposed: queue
  starvation (oldest queued wait), infrastructure churn against real failures
  (claims versus execution failures), terminal-steer conversion (successor
  seeding), and delivery degradation (dead-letter notices against wakeups).
  The 24-hour sums read recently touched Job rows, not an event journal, so
  they are operator trend signals rather than exact ledgers.
  """

  import Ecto.Query

  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.OutboxEntry

  @wakeup_event_types ~w(
    background_agent_job.completed
    background_agent_job.failed
    background_agent_job.waiting
  )
  @window_seconds 24 * 3_600

  @spec metrics(DateTime.t()) :: map()
  def metrics(now \\ DateTime.utc_now(:microsecond)) do
    window_start = DateTime.add(now, -@window_seconds, :second)

    %{
      oldest_queued_seconds: oldest_queued_seconds(now),
      queued_count: count_by_status("queued"),
      running_count: count_by_status("running"),
      claims_24h: touched_sum(window_start, :attempts),
      execution_failures_24h: touched_sum(window_start, :execution_failures),
      succeeded_24h: succeeded_in_window(window_start),
      successor_seeded_24h: successors_seeded_in_window(window_start),
      wakeups_24h: wakeups_in_window(window_start),
      dead_letter_notices_24h: dead_letter_notices_in_window(window_start),
      window_seconds: @window_seconds
    }
  end

  defp oldest_queued_seconds(now) do
    Job
    |> where([job], job.status == "queued")
    |> select([job], min(job.queued_at))
    |> Repo.one()
    |> case do
      %DateTime{} = oldest -> max(DateTime.diff(now, oldest, :second), 0)
      nil -> nil
    end
  end

  defp count_by_status(status) do
    Job
    |> where([job], job.status == ^status)
    |> Repo.aggregate(:count)
  end

  defp touched_sum(window_start, field) do
    Job
    |> where([job], job.updated_at >= ^window_start)
    |> select([job], sum(field(job, ^field)))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp succeeded_in_window(window_start) do
    Job
    |> where([job], job.status == "succeeded")
    |> where([job], job.completed_at >= ^window_start)
    |> Repo.aggregate(:count)
  end

  defp successors_seeded_in_window(window_start) do
    Job
    |> where([job], job.inserted_at >= ^window_start)
    |> where([job], fragment("?->>'seeded_from_steer' = 'true'", job.metadata))
    |> Repo.aggregate(:count)
  end

  defp wakeups_in_window(window_start) do
    ActorEvent
    |> where([event], event.type in ^@wakeup_event_types)
    |> where([event], event.inserted_at >= ^window_start)
    |> Repo.aggregate(:count)
  end

  defp dead_letter_notices_in_window(window_start) do
    OutboxEntry
    |> join(:inner, [entry], event in ActorEvent, on: entry.source_actor_event_id == event.id)
    |> where([entry], like(entry.outbound_key, "ai-dead-letter:%"))
    |> where([_entry, event], event.type in ^@wakeup_event_types)
    |> where([entry, _event], entry.inserted_at >= ^window_start)
    |> Repo.aggregate(:count)
  end
end
