defmodule Ankole.Schedule.Queries do
  @moduledoc false

  require Ash.Query

  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @spec list_cron_schedules(String.t() | nil, String.t() | nil) :: [CronSchedule.t()]
  def list_cron_schedules(agent_uid \\ nil, owner_session_id \\ nil) do
    CronSchedule
    |> maybe_where_agent(agent_uid)
    |> Ash.Query.filter(status != :deleted)
    |> maybe_where_owner_session(owner_session_id)
    |> Ash.Query.sort(agent_uid: :asc, owner_session_id: :asc, name: :asc)
    |> read()
  end

  @spec get_cron_schedule(Ecto.UUID.t()) :: {:ok, CronSchedule.t()} | {:error, :not_found}
  def get_cron_schedule(cron_schedule_id) when is_binary(cron_schedule_id) do
    with {:ok, cron_schedule_id} <- Ecto.UUID.cast(cron_schedule_id),
         %CronSchedule{} = schedule <- Ankole.Schedule.Store.get_cron_schedule(cron_schedule_id) do
      {:ok, schedule}
    else
      _not_found -> {:error, :not_found}
    end
  end

  @spec get_cron_schedule_by_name(String.t(), String.t(), String.t()) ::
          {:ok, CronSchedule.t()} | {:error, :not_found}
  def get_cron_schedule_by_name(agent_uid, owner_session_id, name)
      when is_binary(agent_uid) and is_binary(owner_session_id) and is_binary(name) do
    agent_uid = String.downcase(agent_uid)

    CronSchedule
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and owner_session_id == ^owner_session_id and name == ^name and
        status != :deleted
    )
    |> Ankole.Ash.read_one()
    |> case do
      {:ok, %CronSchedule{} = schedule} -> {:ok, schedule}
      {:ok, nil} -> {:error, :not_found}
    end
  end

  @spec get_scheduled_event(pos_integer()) :: {:ok, ScheduledEvent.t()} | {:error, :not_found}
  def get_scheduled_event(scheduled_event_id) when is_integer(scheduled_event_id) do
    case Ankole.Schedule.Store.get_scheduled_event(scheduled_event_id) do
      %ScheduledEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  @spec list_cron_runs(Ecto.UUID.t(), pos_integer()) :: [ScheduledEvent.t()]
  def list_cron_runs(cron_schedule_id, limit \\ 25)
      when is_binary(cron_schedule_id) and is_integer(limit) and limit > 0 do
    ScheduledEvent
    |> Ash.Query.filter(cron_schedule_id == ^cron_schedule_id)
    |> Ash.Query.sort(due_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> read()
  end

  @checkback_limit_max 500
  @checkback_limit_default 100

  # The console default scope is now the whole installation, and finished
  # checkbacks are retained. Without a bound the default page would return
  # every agent's full history.
  @spec list_checkbacks(String.t() | nil, String.t() | nil, keyword()) :: [ScheduledEvent.t()]
  def list_checkbacks(agent_uid \\ nil, session_id \\ nil, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> bounded_checkback_limit()

    agent_uid
    |> checkbacks_query()
    |> maybe_where_session(session_id)
    |> Ash.Query.sort(due_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> read()
  end

  defp bounded_checkback_limit(value) when is_integer(value) and value > 0,
    do: min(value, @checkback_limit_max)

  defp bounded_checkback_limit(_value), do: @checkback_limit_default

  @spec list_pending_checkbacks(String.t(), String.t(), pos_integer()) :: [ScheduledEvent.t()]
  def list_pending_checkbacks(agent_uid, session_id, limit)
      when is_binary(agent_uid) and is_binary(session_id) and is_integer(limit) and limit > 0 do
    agent_uid
    |> checkbacks_query()
    |> Ash.Query.filter(status == :scheduled)
    |> maybe_where_session(session_id)
    |> Ash.Query.sort(due_at: :asc, inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> read()
  end

  defp checkbacks_query(agent_uid) do
    ScheduledEvent
    |> Ash.Query.filter(kind == "check_back_later")
    |> maybe_where_agent(agent_uid)
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid) when is_binary(agent_uid) do
    agent_uid = String.downcase(agent_uid)
    Ash.Query.filter(query, agent_uid == ^agent_uid)
  end

  defp maybe_where_session(query, nil), do: query

  defp maybe_where_session(query, session_id),
    do: Ash.Query.filter(query, session_id == ^session_id)

  defp maybe_where_owner_session(query, nil), do: query

  defp maybe_where_owner_session(query, owner_session_id),
    do: Ash.Query.filter(query, owner_session_id == ^owner_session_id)

  defp read(query) do
    {:ok, records} = Ankole.Ash.read(query)
    records
  end
end
