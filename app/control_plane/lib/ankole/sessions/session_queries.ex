defmodule Ankole.Sessions.SessionQueries do
  @moduledoc """
  Read-only enumeration of Sessions for one Agent.

  A session is not a first-class table. It is an opaque partition key that
  appears across `cron_schedules` (as the owner conversation),
  `scheduled_events` (as the execution target), and
  `background_agent_jobs` (the last one synthesizes its session id via
  `Ankole.BackgroundAgentJobs.job_session_id/1`).
  This module unions the distinct session keys from those durable sources so the
  console can offer a session picker scoped to one Agent. Derived cron
  execution sessions stay out: they cannot own schedules or other resources,
  and the conversations page already surfaces them.
  """

  import Ash.Expr, only: [expr: 1]

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Schedule.Cron

  @type session :: %{
          session_id: String.t(),
          kind: String.t(),
          title: String.t() | nil,
          status: String.t() | nil,
          last_activity_at: String.t() | nil
        }

  @doc """
  Lists sessions that have durable activity for `agent_uid`, newest first.

  Sessions surface when they own cron schedules, scheduled events, or background
  jobs. A job session carries its title and status; other sessions leave those
  nil. `last_activity_at` is the newest `updated_at` across the contributing rows.
  """
  @spec list_agent_sessions(String.t()) :: [session()]
  def list_agent_sessions(agent_uid) when is_binary(agent_uid) do
    agent_uid = String.downcase(agent_uid)

    cron = cron_sessions(agent_uid)
    events = event_sessions(agent_uid)
    jobs = job_sessions(agent_uid)

    [cron, events, jobs]
    |> Stream.concat()
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.update(acc, entry.session_id, entry, fn existing ->
        merge_session(existing, entry)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.last_activity_at, fn
      nil, nil -> true
      nil, _ -> false
      _, nil -> true
      a, b -> DateTime.compare(a, b) == :gt
    end)
    |> Enum.map(fn entry -> %{entry | last_activity_at: to_iso(entry.last_activity_at)} end)
  end

  # Each source returns maps with the keys the union needs. `kind` marks the
  # origin so the console can prefer a job title when one exists.

  defp cron_sessions(agent_uid) do
    agent_uid
    |> Ankole.Schedule.list_cron_schedules()
    |> Enum.group_by(& &1.owner_session_id, & &1.updated_at)
    |> Enum.map(fn {session_id, times} ->
      at = Enum.max(times, DateTime)
      %{session_id: session_id, kind: "session", title: nil, status: nil, last_activity_at: at}
    end)
  end

  # One row for each session: the newest event, by DISTINCT ON the session.
  defp event_sessions(agent_uid) do
    prefix = Cron.execution_session_prefix()

    [
      query: [
        filter: expr(agent_uid == ^agent_uid and not string_starts_with(session_id, ^prefix)),
        distinct: [:session_id],
        distinct_sort: [session_id: :asc, updated_at: :desc],
        select: [:session_id, :updated_at]
      ]
    ]
    |> Ankole.Schedule.list_scheduled_events!()
    |> Enum.map(fn event ->
      %{
        session_id: event.session_id,
        kind: "session",
        title: nil,
        status: nil,
        last_activity_at: event.updated_at
      }
    end)
  end

  defp job_sessions(agent_uid) do
    [query: [filter: [agent_uid: agent_uid], select: [:id, :status, :title, :updated_at]]]
    |> BackgroundAgentJobs.list_jobs!()
    |> Enum.map(fn job ->
      %{
        session_id: BackgroundAgentJobs.job_session_id(job.id),
        kind: "job",
        title: job.title,
        status: Atom.to_string(job.status),
        last_activity_at: job.updated_at
      }
    end)
  end

  # Prefer the job provenance when both a job and a plain-session entry exist for
  # the same key; otherwise keep the newest activity timestamp.
  defp merge_session(existing, entry) do
    base =
      case {existing.kind, entry.kind} do
        {"job", _} -> %{existing | last_activity_at: latest(existing, entry)}
        {_, "job"} -> %{entry | last_activity_at: latest(existing, entry)}
        _ -> %{existing | last_activity_at: latest(existing, entry)}
      end

    base
  end

  defp latest(%{last_activity_at: a}, %{last_activity_at: b}) do
    case {a, b} do
      {nil, _} -> b
      {_, nil} -> a
      {a, b} -> if DateTime.compare(a, b) == :gt, do: a, else: b
    end
  end

  defp to_iso(nil), do: nil
  defp to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
