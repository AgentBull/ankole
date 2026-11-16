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

  @spec list_room_cron_schedules([String.t()]) :: [CronSchedule.t()]
  def list_room_cron_schedules([]), do: []

  def list_room_cron_schedules(owner_session_ids) when is_list(owner_session_ids) do
    CronSchedule
    |> Ash.Query.filter(
      status in [:active, :paused] and is_nil(owner_job_id) and
        owner_session_id in ^owner_session_ids
    )
    |> Ash.Query.select([
      :id,
      :agent_uid,
      :human_uid,
      :owner_session_id,
      :idempotency_key,
      :status,
      :schedule,
      :timezone,
      :next_fire_at
    ])
    |> read()
  end

  @spec list_active_agent_cron_schedules() :: [CronSchedule.t()]
  def list_active_agent_cron_schedules do
    CronSchedule
    |> Ash.Query.filter(status in [:active, :paused] and is_nil(owner_job_id))
    |> Ash.Query.select([
      :id,
      :name,
      :status,
      :agent_uid,
      :human_uid,
      :owner_session_id,
      :delivery,
      :schedule,
      :timezone,
      :next_fire_at,
      :last_fire_at
    ])
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

  @spec list_cron_runs(Ecto.UUID.t(), pos_integer()) :: [ScheduledEvent.t()]
  def list_cron_runs(cron_schedule_id, limit \\ 25)
      when is_binary(cron_schedule_id) and is_integer(limit) and limit > 0 do
    ScheduledEvent
    |> Ash.Query.filter(cron_schedule_id == ^cron_schedule_id)
    |> Ash.Query.sort(due_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> read()
  end

  @spec list_pending_checkbacks(String.t(), String.t(), pos_integer()) :: [ScheduledEvent.t()]
  def list_pending_checkbacks(agent_uid, session_id, limit)
      when is_binary(agent_uid) and is_binary(session_id) and is_integer(limit) and limit > 0 do
    agent_uid
    |> checkbacks_query()
    |> Ash.Query.filter(status == :scheduled and session_id == ^session_id)
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

  defp maybe_where_owner_session(query, nil), do: query

  defp maybe_where_owner_session(query, owner_session_id),
    do: Ash.Query.filter(query, owner_session_id == ^owner_session_id)

  defp read(query) do
    {:ok, records} = Ankole.Ash.read(query)
    records
  end

  def list_board_cron_schedules do
    CronSchedule
    |> Ash.Query.filter(is_nil(owner_job_id) and status in [:active, :paused])
    |> Ash.Query.sort(next_fire_at: :asc_nils_last, updated_at: :desc)
    |> read()
  end

  def list_board_checkbacks(cutoff) do
    ScheduledEvent
    |> Ash.Query.filter(
      kind == "check_back_later" and
        (status == :scheduled or (status == :failed and updated_at >= ^cutoff))
    )
    |> Ash.Query.sort(due_at: :asc, id: :asc)
    |> read()
  end

  def cron_fire_rollups([]), do: {%{}, MapSet.new()}

  def cron_fire_rollups(rule_ids) when is_list(rule_ids) do
    latest_events =
      ScheduledEvent
      |> Ash.Query.filter(cron_schedule_id in ^rule_ids and kind == "cron_fire")
      |> Ash.Query.distinct([:cron_schedule_id])
      |> Ash.Query.distinct_sort(cron_schedule_id: :asc, due_at: :desc, id: :desc)
      |> read()
      |> Map.new(&{&1.cron_schedule_id, &1})

    pending_manual_ids =
      ScheduledEvent
      |> Ash.Query.filter(
        cron_schedule_id in ^rule_ids and kind == "cron_fire" and status == :scheduled
      )
      |> Ash.Query.select([:cron_schedule_id])
      |> read()
      |> MapSet.new(& &1.cron_schedule_id)

    {latest_events, pending_manual_ids}
  end

  def routine_cron_fire_rollups(schedules_by_routine) when is_map(schedules_by_routine) do
    routine_by_cron =
      for {routine_id, crons} <- schedules_by_routine,
          cron <- crons,
          into: %{},
          do: {cron.id, routine_id}

    cron_ids = Map.keys(routine_by_cron)

    if cron_ids == [] do
      {%{}, MapSet.new()}
    else
      unlinked_events =
        ScheduledEvent
        |> Ash.Query.filter(
          cron_schedule_id in ^cron_ids and kind == "cron_fire" and is_nil(signal_id)
        )
        |> Ash.Query.distinct([:cron_schedule_id])
        |> Ash.Query.distinct_sort(cron_schedule_id: :asc, due_at: :desc, id: :desc)
        |> read()

      latest_by_routine =
        Enum.reduce(unlinked_events, %{}, fn event, acc ->
          routine_id = Map.fetch!(routine_by_cron, event.cron_schedule_id)

          Map.update(acc, routine_id, event, fn prev ->
            if DateTime.compare(event.due_at, prev.due_at) == :gt, do: event, else: prev
          end)
        end)

      pending_manual_routine_ids =
        ScheduledEvent
        |> Ash.Query.filter(
          cron_schedule_id in ^cron_ids and kind == "cron_fire" and status == :scheduled
        )
        |> Ash.Query.select([:cron_schedule_id])
        |> read()
        |> Enum.map(&Map.fetch!(routine_by_cron, &1.cron_schedule_id))
        |> MapSet.new()

      {latest_by_routine, pending_manual_routine_ids}
    end
  end

  def list_unlinked_cron_fire_events([], _limit), do: []

  def list_unlinked_cron_fire_events(cron_ids, limit)
      when is_list(cron_ids) and is_integer(limit) and limit > 0 do
    ScheduledEvent
    |> Ash.Query.filter(
      cron_schedule_id in ^cron_ids and kind == "cron_fire" and is_nil(signal_id)
    )
    |> Ash.Query.sort(due_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> read()
  end

  def schedules_by_owner_jobs([]), do: %{}

  def schedules_by_owner_jobs(job_ids) when is_list(job_ids) do
    CronSchedule
    |> Ash.Query.filter(owner_job_id in ^job_ids and status != :deleted)
    |> Ash.Query.sort(next_fire_at: :asc_nils_last, name: :asc)
    |> read()
    |> Enum.group_by(& &1.owner_job_id)
  end

  def list_cron_fire_events(cron_schedule_id, limit)
      when is_binary(cron_schedule_id) and is_integer(limit) and limit > 0 do
    ScheduledEvent
    |> Ash.Query.filter(cron_schedule_id == ^cron_schedule_id and kind == "cron_fire")
    |> Ash.Query.sort(due_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> read()
  end
end
