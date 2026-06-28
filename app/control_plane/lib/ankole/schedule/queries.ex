defmodule Ankole.Schedule.Queries do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @spec list_cron_schedules(String.t(), String.t() | nil) :: [CronSchedule.t()]
  def list_cron_schedules(agent_uid, session_id \\ nil) when is_binary(agent_uid) do
    CronSchedule
    |> where([schedule], schedule.agent_uid == ^String.downcase(agent_uid))
    |> maybe_where_session(session_id)
    |> order_by([schedule], asc: schedule.agent_uid, asc: schedule.session_id, asc: schedule.name)
    |> Repo.all()
  end

  @spec get_cron_schedule(Ecto.UUID.t()) :: {:ok, CronSchedule.t()} | {:error, :not_found}
  def get_cron_schedule(cron_schedule_id) when is_binary(cron_schedule_id) do
    case Repo.get(CronSchedule, cron_schedule_id) do
      %CronSchedule{} = schedule -> {:ok, schedule}
      nil -> {:error, :not_found}
    end
  end

  @spec get_scheduled_event(Ecto.UUID.t()) :: {:ok, ScheduledEvent.t()} | {:error, :not_found}
  def get_scheduled_event(scheduled_event_id) when is_binary(scheduled_event_id) do
    case Repo.get(ScheduledEvent, scheduled_event_id) do
      %ScheduledEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  @spec list_cron_runs(Ecto.UUID.t(), pos_integer()) :: [ScheduledEvent.t()]
  def list_cron_runs(cron_schedule_id, limit \\ 25)
      when is_binary(cron_schedule_id) and is_integer(limit) and limit > 0 do
    ScheduledEvent
    |> where([event], event.cron_schedule_id == ^cron_schedule_id)
    |> order_by([event], desc: event.due_at, desc: event.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_checkbacks(String.t(), String.t() | nil) :: [ScheduledEvent.t()]
  def list_checkbacks(agent_uid, session_id \\ nil) when is_binary(agent_uid) do
    ScheduledEvent
    |> where([event], event.kind == "check_back_later")
    |> where([event], event.agent_uid == ^String.downcase(agent_uid))
    |> maybe_where_session(session_id)
    |> order_by([event], desc: event.due_at, desc: event.inserted_at)
    |> Repo.all()
  end

  defp maybe_where_session(query, nil), do: query

  defp maybe_where_session(query, session_id),
    do: where(query, [row], row.session_id == ^session_id)
end
