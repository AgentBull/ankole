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

  require Ash.Query

  alias Ankole.BackgroundAgentJobs.JobSignals
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Sessions.BackgroundAgentJobCap

  @wakeup_event_types ~w(
    background_agent_job.completed
    background_agent_job.failed
    background_agent_job.input_undeliverable
    background_agent_job.waiting
  )
  @window_seconds 24 * 3_600

  @spec metrics(DateTime.t()) :: map()
  def metrics(now \\ DateTime.utc_now(:microsecond)) do
    window_start = DateTime.add(now, -@window_seconds, :second)
    cap = BackgroundAgentJobCap.max_running_per_agent()
    %{agents: agents_at_cap, queued: queued_behind_cap} = agent_cap_pressure(cap)

    %{
      oldest_queued_seconds: oldest_queued_seconds(now),
      queued_count: count(Ash.Query.filter(Job, status == :queued)),
      running_count: count(Ash.Query.filter(Job, status == :running)),
      max_running_per_agent: cap,
      agents_at_running_cap: agents_at_cap,
      queued_behind_running_cap: queued_behind_cap,
      claims_24h: touched_sum(window_start, :attempts),
      execution_failures_24h: touched_sum(window_start, :execution_failures),
      succeeded_24h:
        count(Ash.Query.filter(Job, status == :succeeded and completed_at >= ^window_start)),
      successor_seeded_24h:
        count(
          Ash.Query.filter(
            Job,
            inserted_at >= ^window_start and
              fragment("?->>'seeded_from_steer' = 'true'", metadata)
          )
        ),
      wakeups_24h: wakeups_in_window(window_start),
      dead_letter_notices_24h: dead_letter_notices_in_window(window_start),
      window_seconds: @window_seconds
    }
  end

  defp oldest_queued_seconds(now) do
    %{oldest: oldest} =
      Job
      |> Ash.Query.filter(status == :queued)
      |> Ankole.Ash.aggregate!({:oldest, :min, field: :queued_at})

    if oldest, do: max(DateTime.diff(now, oldest, :second), 0)
  end

  # Counts Agents at their per-Agent running cap and Jobs queued behind that cap.
  defp agent_cap_pressure(cap) do
    statuses = Job.running_statuses() ++ [:queued]

    Job
    |> Ash.Query.filter(status in ^statuses)
    |> Ash.Query.select([:agent_uid, :status])
    |> Ankole.Ash.read!()
    |> Enum.group_by(& &1.agent_uid, & &1.status)
    |> Enum.map(fn {_agent_uid, statuses} ->
      %{
        running: Enum.count(statuses, &(&1 != :queued)),
        queued: Enum.count(statuses, &(&1 == :queued))
      }
    end)
    |> Enum.filter(&(&1.running >= cap and &1.queued > 0))
    |> Enum.reduce(%{agents: 0, queued: 0}, fn agent, acc ->
      %{agents: acc.agents + 1, queued: acc.queued + agent.queued}
    end)
  end

  defp count(query) do
    %{count: count} = Ankole.Ash.aggregate!(query, {:count, :count})
    count
  end

  defp touched_sum(window_start, field) do
    %{sum: sum} =
      Job
      |> Ash.Query.filter(updated_at >= ^window_start)
      |> Ankole.Ash.aggregate!({:sum, :sum, field: field})

    sum || 0
  end

  defp wakeups_in_window(window_start) do
    [type: [in: @wakeup_event_types], inserted_at: [greater_than_or_equal: window_start]]
    |> JobSignals.list(select: [:id])
    |> length()
  end

  defp dead_letter_notices_in_window(window_start) do
    signal_ids =
      Ankole.Conversations.list_intents!(
        query: [
          filter: [
            outbound_key: [string_starts_with: "ai-dead-letter:"],
            inserted_at: [greater_than_or_equal: window_start]
          ],
          select: [:source_signal_id]
        ]
      )
      |> Enum.map(& &1.source_signal_id)
      |> Enum.reject(&is_nil/1)

    [id: [in: Enum.uniq(signal_ids)], type: [in: @wakeup_event_types]]
    |> JobSignals.list(select: [:id])
    |> MapSet.new(& &1.id)
    |> then(fn wakeups -> Enum.count(signal_ids, &MapSet.member?(wakeups, &1)) end)
  end
end
