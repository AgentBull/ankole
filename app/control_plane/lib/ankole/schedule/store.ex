defmodule Ankole.Schedule.Store do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.ActorRuntime.Jobs.FireScheduledEvent
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @spec insert_event_and_wake_in_tx(module(), map(), keyword()) ::
          {:ok, %{status: :scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def insert_event_and_wake_in_tx(repo, attrs, opts) do
    changeset = ScheduledEvent.changeset(%ScheduledEvent{}, attrs)

    with {:ok, event} <- repo.insert(changeset),
         {:ok, job} <- insert_wake_job(event, opts),
         {:ok, event} <-
           event
           |> ScheduledEvent.changeset(%{oban_job_id: job.id})
           |> repo.update() do
      {:ok, %{status: :scheduled, scheduled_event: event}}
    end
  end

  @spec insert_idempotent_event_and_wake_in_tx(module(), map(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def insert_idempotent_event_and_wake_in_tx(repo, attrs, opts) do
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

  @spec lock_live_recurring_cron_events(module(), Ecto.UUID.t()) :: [ScheduledEvent.t()]
  def lock_live_recurring_cron_events(repo, cron_schedule_id) do
    ScheduledEvent
    |> where([event], event.kind == "cron_fire")
    |> where([event], event.cron_schedule_id == ^cron_schedule_id)
    |> where([event], event.status in ["scheduled", "firing"])
    |> where(
      [event],
      fragment("COALESCE(?->>'trigger', 'scheduled') = 'scheduled'", event.wake_payload)
    )
    |> order_by([event], asc: event.id)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  @spec cancel_pending_cron_events(module(), CronSchedule.t(), DateTime.t()) ::
          {:ok, [ScheduledEvent.t()]} | {:error, term()}
  def cancel_pending_cron_events(repo, %CronSchedule{} = schedule, now) do
    events =
      ScheduledEvent
      |> where([event], event.kind == "cron_fire")
      |> where([event], event.cron_schedule_id == ^schedule.id)
      |> where([event], event.status == "scheduled")
      |> lock("FOR UPDATE")
      |> repo.all()

    cancel_scheduled_events(repo, events, now, "cron_schedule_deleted")
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

  @spec lock_cron_by_idempotency(module(), map()) ::
          {:ok, CronSchedule.t()} | {:error, :cron_schedule_not_found}
  def lock_cron_by_idempotency(repo, attrs) do
    query =
      CronSchedule
      |> where([schedule], schedule.agent_uid == ^attrs.agent_uid)
      |> where([schedule], schedule.session_id == ^attrs.session_id)
      |> where([schedule], schedule.idempotency_key == ^attrs.idempotency_key)
      |> lock("FOR UPDATE")

    case repo.one(query) do
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

  @spec lock_scheduled_event(module(), pos_integer()) :: ScheduledEvent.t() | nil
  def lock_scheduled_event(repo, scheduled_event_id) do
    ScheduledEvent
    |> where([event], event.id == ^scheduled_event_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @spec reject_terminal(CronSchedule.t()) ::
          :ok | {:error, :cron_schedule_deleted | :cron_schedule_completed}
  def reject_terminal(%CronSchedule{status: "deleted"}), do: {:error, :cron_schedule_deleted}
  def reject_terminal(%CronSchedule{status: "completed"}), do: {:error, :cron_schedule_completed}
  def reject_terminal(%CronSchedule{}), do: :ok

  @doc """
  Counts the recurrence's consumed due slots.

  A slot is consumed when its scheduled fire was claimed, whatever happened
  next: `firing`, `fired`, and `failed` rows all count once, while retries of
  one slot reuse its row and never count again. Manually requested fires are
  outside the recurrence and do not count. This is what an occurrence `count`
  bound measures.
  """
  @spec count_consumed_cron_slots(module(), Ecto.UUID.t()) :: non_neg_integer()
  def count_consumed_cron_slots(repo, cron_schedule_id) do
    ScheduledEvent
    |> where([event], event.kind == "cron_fire")
    |> where([event], event.cron_schedule_id == ^cron_schedule_id)
    |> where([event], event.status in ["firing", "fired", "failed"])
    |> where(
      [event],
      fragment("COALESCE(?->>'trigger', 'scheduled') = 'scheduled'", event.wake_payload)
    )
    |> repo.aggregate(:count)
  end

  @spec cron_source_event_id(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def cron_source_event_id(cron_schedule_id, %DateTime{} = slot_at) do
    "cron:#{cron_schedule_id}:#{DateTime.to_iso8601(slot_at)}"
  end

  @spec cron_arm_idempotency_key(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def cron_arm_idempotency_key(cron_schedule_id, %DateTime{} = slot_at) do
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
