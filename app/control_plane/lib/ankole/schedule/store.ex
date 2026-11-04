defmodule Ankole.Schedule.Store do
  @moduledoc false

  require Ash.Query

  alias Ankole.Repo
  alias Ankole.Sessions.Jobs.FireScheduledEvent
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  def reserve_event_id do
    [[id]] =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('scheduled_events', 'id'))", []).rows

    id
  end

  @spec insert_idempotent_event_and_wake_in_tx(map(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def insert_idempotent_event_and_wake_in_tx(attrs, opts) do
    with {:ok, persisted} <-
           create_event(
             attrs,
             if(attrs.kind == "cron_fire", do: :schedule_cron_event, else: :schedule_event)
           ) do
      case Ash.Resource.get_metadata(persisted, :upsert_action) do
        :insert ->
          with :ok <-
                 if(persisted.kind == "check_back_later",
                   do:
                     Ankole.Signals.put_source_binding_in_tx(
                       "scheduled-event://#{persisted.id}",
                       persisted.agent_uid,
                       persisted.session_id,
                       Map.get(attrs, :automation_job_id)
                     ),
                   else: :ok
                 ),
               {:ok, _job} <- insert_wake_job(persisted, opts) do
            {:ok, %{status: :scheduled, scheduled_event: persisted}}
          end

        :update ->
          {:ok, %{status: :already_scheduled, scheduled_event: persisted}}
      end
    end
  end

  def create_event(attrs, action \\ :create_event),
    do:
      Ankole.Ash.create(ScheduledEvent, action, Map.delete(attrs, :automation_job_id),
        touch_update_defaults?: false
      )

  @doc "Locks the scheduled events that a query selects and cancels them."
  @spec cancel_matching_in_tx(Ash.Query.t(), DateTime.t(), String.t()) ::
          {:ok, [ScheduledEvent.t()]} | {:error, term()}
  def cancel_matching_in_tx(query, now, reason),
    do: query |> lock_events() |> cancel_scheduled_events(now, reason)

  @spec cancel_pending_cron_events(CronSchedule.t(), DateTime.t()) ::
          {:ok, [ScheduledEvent.t()]} | {:error, term()}
  def cancel_pending_cron_events(%CronSchedule{id: schedule_id}, now) do
    ScheduledEvent
    |> Ash.Query.filter(
      kind == "cron_fire" and cron_schedule_id == ^schedule_id and status == :scheduled
    )
    |> lock_events()
    |> cancel_scheduled_events(now, "cron_schedule_deleted")
  end

  defp lock_events(query) do
    {:ok, events} =
      query
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read(lock_identity: {:rows, "scheduled_events", :id})

    events
  end

  @spec cancel_scheduled_events([ScheduledEvent.t()], DateTime.t(), String.t()) ::
          {:ok, [ScheduledEvent.t()]} | {:error, term()}
  defp cancel_scheduled_events([], _now, _reason), do: {:ok, []}

  defp cancel_scheduled_events(events, now, reason) do
    events
    |> Enum.map(fn event ->
      Ankole.Ash.update(event, :cancel, %{
        cancelled_at: now,
        last_fire_error: %{"reason" => reason}
      })
    end)
    |> Attrs.collect_results()
  end

  @spec lock_cron_by_idempotency(map()) ::
          {:ok, CronSchedule.t()} | {:error, :cron_schedule_not_found}
  def lock_cron_by_idempotency(attrs) do
    query =
      if attrs[:owner_job_id] do
        Ash.Query.filter(
          CronSchedule,
          owner_job_id == ^attrs.owner_job_id and idempotency_key == ^attrs.idempotency_key
        )
      else
        Ash.Query.filter(
          CronSchedule,
          agent_uid == ^attrs.agent_uid and owner_session_id == ^attrs.owner_session_id and
            idempotency_key == ^attrs.idempotency_key
        )
      end

    # Creation only adds a default Binding for a new row. An idempotent retry
    # keeps existing subscriptions, so neither path locks other consumers.
    query = Ash.Query.lock(query, :for_update)

    with %CronSchedule{} = schedule <-
           read_one(query, lock_identity: {:rows, "cron_schedules", :id}) do
      {:ok, schedule}
    else
      nil -> {:error, :cron_schedule_not_found}
    end
  end

  @doc """
  Locks the source owner before the rule. Job-owned rules have a fixed default
  destination, so edits do not lock their independent fanout consumers.

  Agent-owned rules lock their current Bindings and any requested destination
  before editing. Dispatch passes `:prepared` after acquiring its delivery locks.
  When the current Binding changes before the lock, the result is
  `{:error, :cron_schedule_changed}`.
  """
  @spec lock_cron_schedule(Ecto.UUID.t(), :current | :prepared | pos_integer() | nil) ::
          CronSchedule.t() | nil | {:error, :cron_schedule_changed}
  def lock_cron_schedule(cron_schedule_id, automation_job_id \\ :current)

  def lock_cron_schedule(cron_schedule_id, :prepared), do: lock_cron_row(cron_schedule_id)

  def lock_cron_schedule(cron_schedule_id, automation_job_id) do
    case get_cron_schedule(cron_schedule_id) do
      nil ->
        nil

      %CronSchedule{owner_job_id: owner} when is_integer(owner) ->
        Ankole.AutomationJobs.lock_job_in_tx(owner)
        lock_cron_row(cron_schedule_id)

      %CronSchedule{} = snapshot ->
        Ankole.Signals.lock_source_bindings_in_tx(
          "schedule://#{cron_schedule_id}",
          if(is_integer(automation_job_id), do: automation_job_id)
        )

        consumer =
          if automation_job_id == :current,
            do: Ankole.Signals.source_automation_job_id(snapshot),
            else: automation_job_id

        if is_integer(consumer), do: Ankole.AutomationJobs.lock_job_in_tx(consumer)
        schedule = lock_cron_row(cron_schedule_id)

        if automation_job_id == :current and not is_nil(schedule) and
             Ankole.Signals.source_automation_job_id(schedule) !=
               Ankole.Signals.source_automation_job_id(snapshot),
           do: {:error, :cron_schedule_changed},
           else: schedule
    end
  end

  @doc "Reads one cron schedule without a lock, or `nil`."
  def get_cron_schedule(cron_schedule_id),
    do: CronSchedule |> Ash.Query.filter(id == ^cron_schedule_id) |> read_one()

  @doc "Reads one scheduled event without a lock, or `nil`."
  def get_scheduled_event(scheduled_event_id),
    do: ScheduledEvent |> Ash.Query.filter(id == ^scheduled_event_id) |> read_one()

  defp lock_cron_row(cron_schedule_id) do
    CronSchedule
    |> Ash.Query.filter(id == ^cron_schedule_id)
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {"cron_schedules", cron_schedule_id})
  end

  @spec lock_scheduled_event(pos_integer()) :: ScheduledEvent.t() | nil
  def lock_scheduled_event(scheduled_event_id) do
    ScheduledEvent
    |> Ash.Query.filter(id == ^scheduled_event_id)
    |> Ash.Query.lock(:for_update)
    |> read_one(lock_identity: {"scheduled_events", scheduled_event_id})
  end

  @spec reject_terminal(CronSchedule.t()) ::
          :ok | {:error, :cron_schedule_deleted | :cron_schedule_completed}
  def reject_terminal(%CronSchedule{status: :deleted}), do: {:error, :cron_schedule_deleted}
  def reject_terminal(%CronSchedule{status: :completed}), do: {:error, :cron_schedule_completed}
  def reject_terminal(%CronSchedule{}), do: :ok

  @doc """
  Counts the recurrence's consumed due slots.

  A slot is consumed by a `fired` or `failed` history row. Oban retries
  do not write intermediate rows, so one slot counts once. Manually requested fires are
  outside the recurrence and do not count. This is what an occurrence `count`
  bound measures.
  """
  @spec count_consumed_cron_slots(Ecto.UUID.t()) :: non_neg_integer()
  def count_consumed_cron_slots(cron_schedule_id) do
    ScheduledEvent
    |> Ash.Query.filter(
      kind == "cron_fire" and cron_schedule_id == ^cron_schedule_id and
        status in [:fired, :failed] and
        fragment("COALESCE(?->>'trigger', 'scheduled') = 'scheduled'", wake_payload)
    )
    |> Ankole.Ash.count!()
  end

  @spec cron_source_event_id(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def cron_source_event_id(cron_schedule_id, %DateTime{} = slot_at) do
    "cron:#{cron_schedule_id}:#{DateTime.to_iso8601(slot_at)}"
  end

  @spec cron_fire_idempotency_key(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def cron_fire_idempotency_key(cron_schedule_id, %DateTime{} = slot_at) do
    "cron-arm:#{cron_schedule_id}:#{DateTime.to_iso8601(slot_at)}:#{Ecto.UUID.generate()}"
  end

  @spec cron_manual_idempotency_key(Ecto.UUID.t(), String.t()) :: String.t()
  def cron_manual_idempotency_key(cron_schedule_id, request_id) when is_binary(request_id) do
    "cron-manual:#{cron_schedule_id}:#{request_id}"
  end

  defp insert_wake_job(%ScheduledEvent{} = event, opts) do
    insert_fun = Keyword.get(opts, :wake_insert, &Oban.insert/1)

    event.id
    |> scheduled_event_job_changeset(event.due_at)
    |> insert_fun.()
  end

  defp scheduled_event_job_changeset(event_id, due_at) do
    FireScheduledEvent.new(%{"scheduled_event_id" => event_id}, scheduled_at: due_at)
  end

  defp read_one(query, opts \\ []) do
    {:ok, record} = Ankole.Ash.read_one(query, opts)
    record
  end
end
