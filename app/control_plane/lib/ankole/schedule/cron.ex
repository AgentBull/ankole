defmodule Ankole.Schedule.Cron do
  @moduledoc false

  alias Ankole.Repo
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Normalizer
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store

  @spec create_cron_schedule(map(), keyword()) ::
          {:ok, %{status: :created | :already_exists, cron_schedule: CronSchedule.t()}}
          | {:error, term()}
  def create_cron_schedule(attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, attrs} <- Normalizer.cron_schedule_attrs(attrs, now, opts),
           {:ok, result} <- insert_cron_schedule_in_tx(repo, attrs, now, opts) do
        {:ok, result}
      end
    end)
  end

  @spec update_cron_schedule(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def update_cron_schedule(cron_schedule_id, attrs, opts \\ [])
      when is_binary(cron_schedule_id) and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
           :ok <- Store.reject_deleted(schedule),
           {:ok, attrs} <- Normalizer.cron_schedule_update_attrs(schedule, attrs, now, opts),
           {:ok, schedule} <- schedule |> CronSchedule.changeset(attrs) |> repo.update(),
           {:ok, _events} <- Store.cancel_recurring_cron_events(repo, schedule, now),
           {:ok, schedule} <- maybe_arm_active_cron_in_tx(repo, schedule, now, opts) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec pause_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def pause_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
           :ok <- Store.reject_deleted(schedule),
           {:ok, schedule} <-
             schedule
             |> CronSchedule.changeset(%{status: "paused", next_fire_at: nil})
             |> repo.update(),
           {:ok, _events} <- Store.cancel_recurring_cron_events(repo, schedule, now) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec resume_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def resume_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
           :ok <- Store.reject_deleted(schedule),
           {:ok, next_fire_at} <-
             Planner.next_fire_after(schedule.schedule, schedule.timezone, now),
           {:ok, schedule} <-
             schedule
             |> CronSchedule.changeset(%{status: "active", next_fire_at: next_fire_at})
             |> repo.update(),
           {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, opts) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec remove_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def remove_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
           {:ok, schedule} <-
             schedule
             |> CronSchedule.changeset(%{status: "deleted", next_fire_at: nil})
             |> repo.update(),
           {:ok, _events} <- Store.cancel_pending_cron_events(repo, schedule, now) do
        {:ok, schedule}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec run_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def run_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
           :ok <- Store.reject_deleted(schedule),
           slot_at <- Keyword.get(opts, :slot_at, now),
           {:ok, result} <-
             arm_cron_fire_in_tx(
               repo,
               schedule,
               slot_at,
               now,
               opts
               |> Keyword.put(:due_at, now)
               |> Keyword.put(:trigger, "manual")
             ) do
        {:ok, result}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec arm_cron_fire_in_tx(module(), CronSchedule.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, %{status: :scheduled | :already_scheduled, scheduled_event: ScheduledEvent.t()}}
          | {:error, term()}
  def arm_cron_fire_in_tx(repo, %CronSchedule{} = schedule, slot_at, now, opts) do
    trigger = Keyword.get(opts, :trigger, "scheduled")
    due_at = Keyword.get(opts, :due_at, slot_at)
    delivery = schedule.delivery || %{}

    attrs = %{
      kind: "cron_fire",
      status: "scheduled",
      agent_uid: schedule.agent_uid,
      session_id: schedule.session_id,
      binding_name: schedule.binding_name,
      signal_channel_id: Attrs.map_text(delivery, "signal_channel_id"),
      provider_thread_id: Attrs.map_text(delivery, "provider_thread_id"),
      due_at: due_at,
      timezone: schedule.timezone,
      requested_at: now,
      idempotency_key: Store.cron_idempotency_key(schedule.id, slot_at),
      cron_schedule_id: schedule.id,
      cron_fire_slot_at: slot_at,
      # Source table: created_by.origin_ai_message_id is ai_gateway_messages.id
      # captured when the cron definition was created.
      origin_ai_message_id: Attrs.map_text(schedule.created_by || %{}, "origin_ai_message_id"),
      source_provenance: %{
        "cron_schedule_id" => schedule.id,
        "trigger" => trigger
      },
      wake_payload: %{
        "trigger" => trigger,
        "cron_schedule_id" => schedule.id,
        "cron_schedule_name" => schedule.name,
        "cron_fire_slot_at" => DateTime.to_iso8601(slot_at),
        "due_at" => DateTime.to_iso8601(due_at),
        "timezone" => schedule.timezone,
        "payload" => schedule.payload || %{},
        "delivery" => delivery
      },
      last_fire_error: %{}
    }

    Store.insert_event_and_wake_in_tx(repo, attrs, opts)
  end

  @spec validate_fire_schedule(CronSchedule.t(), ScheduledEvent.t()) ::
          :ok | {:cancel, :cron_schedule_not_active}
  def validate_fire_schedule(%CronSchedule{status: status}, %ScheduledEvent{} = event) do
    case {event_trigger(event), status} do
      {"scheduled", "active"} -> :ok
      {"manual", status} when status in ["active", "paused", "failed"] -> :ok
      {_trigger, _status} -> {:cancel, :cron_schedule_not_active}
    end
  end

  @spec advance_after_fire(
          module(),
          CronSchedule.t(),
          ScheduledEvent.t(),
          DateTime.t(),
          keyword()
        ) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def advance_after_fire(repo, %CronSchedule{} = schedule, %ScheduledEvent{} = event, now, opts) do
    case event_trigger(event) do
      "manual" ->
        {:ok, schedule}

      "scheduled" ->
        with {:ok, next_fire_at} <-
               Planner.next_fire_after(schedule.schedule, schedule.timezone, now),
             {:ok, schedule} <-
               schedule
               |> CronSchedule.changeset(%{
                 last_fire_at: event.cron_fire_slot_at,
                 next_fire_at: next_fire_at
               })
               |> repo.update(),
             {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, opts) do
          {:ok, schedule}
        end
    end
  end

  defp event_trigger(%ScheduledEvent{} = event) do
    get_in(event.wake_payload || %{}, ["trigger"]) || "scheduled"
  end

  defp insert_cron_schedule_in_tx(repo, attrs, now, opts) do
    changeset = CronSchedule.changeset(%CronSchedule{}, attrs)

    with {:ok, attempted} <-
           repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:agent_uid, :session_id, :idempotency_key],
             returning: true
           ),
         {:ok, persisted} <- Store.fetch_cron_by_idempotency(repo, attrs) do
      case attempted.id == persisted.id do
        true ->
          with {:ok, persisted} <- maybe_arm_active_cron_in_tx(repo, persisted, now, opts) do
            {:ok, %{status: :created, cron_schedule: persisted}}
          end

        false ->
          {:ok, %{status: :already_exists, cron_schedule: persisted}}
      end
    end
  end

  defp maybe_arm_active_cron_in_tx(repo, %CronSchedule{status: "active"} = schedule, now, opts) do
    with {:ok, next_fire_at} <- Planner.next_fire_after(schedule.schedule, schedule.timezone, now),
         {:ok, schedule} <-
           schedule
           |> CronSchedule.changeset(%{next_fire_at: next_fire_at})
           |> repo.update(),
         {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, opts) do
      {:ok, schedule}
    end
  end

  defp maybe_arm_active_cron_in_tx(_repo, %CronSchedule{} = schedule, _now, _opts),
    do: {:ok, schedule}
end
