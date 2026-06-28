defmodule Ankole.Schedule.Store do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Jobs.FireScheduledEvent
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @spec insert_event_and_wake_in_tx(module(), map(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def insert_event_and_wake_in_tx(repo, attrs, opts) do
    changeset = ScheduledEvent.changeset(%ScheduledEvent{}, attrs)

    with {:ok, attempted} <-
           repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:kind, :agent_uid, :session_id, :idempotency_key],
             returning: true
           ),
         {:ok, persisted} <- fetch_event_by_idempotency(repo, attrs) do
      case attempted.id == persisted.id and is_nil(persisted.oban_job_id) do
        true ->
          with {:ok, job} <- insert_wake_job(persisted, opts),
               {:ok, event} <-
                 persisted
                 |> ScheduledEvent.changeset(%{oban_job_id: job.id})
                 |> repo.update() do
            {:ok, %{status: :scheduled, scheduled_event: event}}
          end

        false ->
          {:ok, %{status: :already_scheduled, scheduled_event: persisted}}
      end
    end
  end

  @spec cancel_future_cron_events(module(), CronSchedule.t(), DateTime.t()) ::
          {:ok, [ScheduledEvent.t()]} | {:error, term()}
  def cancel_future_cron_events(repo, %CronSchedule{} = schedule, now) do
    events =
      ScheduledEvent
      |> where([event], event.kind == "cron_fire")
      |> where([event], event.cron_schedule_id == ^schedule.id)
      |> where([event], event.status == "scheduled")
      |> lock("FOR UPDATE")
      |> repo.all()

    cancel_scheduled_events(repo, events, now, "cron_schedule_changed")
  end

  @spec cancel_scheduled_events(module(), [ScheduledEvent.t()], DateTime.t(), String.t()) ::
          {:ok, [ScheduledEvent.t()]} | {:error, term()}
  def cancel_scheduled_events(_repo, [], _now, _reason), do: {:ok, []}

  def cancel_scheduled_events(repo, events, now, reason) do
    events
    |> Enum.map(fn event ->
      event
      |> ScheduledEvent.changeset(%{
        status: "cancelled",
        cancelled_at: now,
        last_fire_error: %{"reason" => reason}
      })
      |> repo.update()
    end)
    |> Attrs.collect_results()
  end

  @spec fetch_cron_by_idempotency(module(), map()) ::
          {:ok, CronSchedule.t()} | {:error, :cron_schedule_not_found}
  def fetch_cron_by_idempotency(repo, attrs) do
    case repo.get_by(CronSchedule,
           agent_uid: attrs.agent_uid,
           session_id: attrs.session_id,
           idempotency_key: attrs.idempotency_key
         ) do
      %CronSchedule{} = schedule -> {:ok, schedule}
      nil -> {:error, :cron_schedule_not_found}
    end
  end

  @spec fetch_event_by_idempotency(module(), map()) ::
          {:ok, ScheduledEvent.t()} | {:error, :scheduled_event_not_found}
  def fetch_event_by_idempotency(repo, attrs) do
    case repo.get_by(ScheduledEvent,
           kind: attrs.kind,
           agent_uid: attrs.agent_uid,
           session_id: attrs.session_id,
           idempotency_key: attrs.idempotency_key
         ) do
      %ScheduledEvent{} = event -> {:ok, event}
      nil -> {:error, :scheduled_event_not_found}
    end
  end

  @spec lock_cron_schedule(module(), Ecto.UUID.t()) :: CronSchedule.t() | nil
  def lock_cron_schedule(repo, cron_schedule_id) do
    CronSchedule
    |> where([schedule], schedule.id == ^cron_schedule_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @spec lock_scheduled_event(module(), Ecto.UUID.t()) :: ScheduledEvent.t() | nil
  def lock_scheduled_event(repo, scheduled_event_id) do
    ScheduledEvent
    |> where([event], event.id == ^scheduled_event_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @spec reject_deleted(CronSchedule.t()) :: :ok | {:error, :cron_schedule_deleted}
  def reject_deleted(%CronSchedule{status: "deleted"}), do: {:error, :cron_schedule_deleted}
  def reject_deleted(%CronSchedule{}), do: :ok

  @spec cron_idempotency_key(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def cron_idempotency_key(cron_schedule_id, %DateTime{} = slot_at) do
    "cron:#{cron_schedule_id}:#{DateTime.to_iso8601(slot_at)}"
  end

  defp insert_wake_job(%ScheduledEvent{} = event, opts) do
    insert_fun = Keyword.get(opts, :wake_insert, &Oban.insert/1)

    event.id
    |> scheduled_event_job_changeset(event.due_at)
    |> insert_fun.()
  end

  defp scheduled_event_job_changeset(event_id, due_at) do
    FireScheduledEvent.new(%{"scheduled_event_id" => event_id},
      scheduled_at: due_at,
      unique: [
        fields: [:worker, :args],
        keys: [:scheduled_event_id],
        states: :incomplete
      ]
    )
  end
end
