defmodule Ankole.Schedule.Cron do
  @moduledoc false

  import Ecto.Query, warn: false

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
           {:ok, _events} <- Store.cancel_future_cron_events(repo, schedule, now),
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
           {:ok, _events} <- Store.cancel_future_cron_events(repo, schedule, now) do
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
           {:ok, _events} <- Store.cancel_future_cron_events(repo, schedule, now) do
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

  @spec cancel_due_cron_events_for_reset_in_tx(module(), map(), DateTime.t(), DateTime.t()) ::
          {:ok, %{cancelled_events: non_neg_integer(), rearmed_schedules: non_neg_integer()}}
          | {:error, term()}
  def cancel_due_cron_events_for_reset_in_tx(
        repo,
        actor_key,
        %DateTime{} = reset_at,
        %DateTime{} = now
      )
      when is_map(actor_key) do
    agent_uid = Attrs.map_text(actor_key, "agent_uid")
    session_id = Attrs.map_text(actor_key, "session_id")

    if is_binary(agent_uid) and is_binary(session_id) do
      events =
        ScheduledEvent
        |> where([event], event.kind == "cron_fire")
        |> where([event], event.status == "scheduled")
        |> where([event], event.agent_uid == ^String.downcase(agent_uid))
        |> where([event], event.session_id == ^session_id)
        |> where([event], event.due_at <= ^reset_at)
        |> lock("FOR UPDATE")
        |> repo.all()

      schedule_ids =
        events
        |> Enum.map(& &1.cron_schedule_id)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      with {:ok, _cancelled} <-
             Store.cancel_scheduled_events(repo, events, now, "session_reset_due"),
           {:ok, rearmed_count} <-
             rearm_active_cron_schedules_after_reset(repo, schedule_ids, now) do
        {:ok, %{cancelled_events: length(events), rearmed_schedules: rearmed_count}}
      end
    else
      {:ok, %{cancelled_events: 0, rearmed_schedules: 0}}
    end
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

  @spec validate_fire_schedule_active(CronSchedule.t(), ScheduledEvent.t()) ::
          :ok | {:cancel, :cron_schedule_not_active}
  def validate_fire_schedule_active(%CronSchedule{status: "active"}, _event), do: :ok

  def validate_fire_schedule_active(%CronSchedule{}, _event),
    do: {:cancel, :cron_schedule_not_active}

  @spec advance_after_fire(
          module(),
          CronSchedule.t(),
          ScheduledEvent.t(),
          DateTime.t(),
          keyword()
        ) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def advance_after_fire(repo, %CronSchedule{} = schedule, %ScheduledEvent{} = event, now, opts) do
    case get_in(event.wake_payload || %{}, ["trigger"]) do
      "manual" ->
        {:ok, schedule}

      _trigger ->
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

  defp rearm_active_cron_schedules_after_reset(_repo, [], _now), do: {:ok, 0}

  defp rearm_active_cron_schedules_after_reset(repo, schedule_ids, now) do
    schedule_ids
    |> Enum.map(&rearm_active_cron_schedule_after_reset(repo, &1, now))
    |> Attrs.collect_results()
    |> case do
      {:ok, results} ->
        {:ok, Enum.count(results, &(&1 == :rearmed))}

      {:error, _reason} = error ->
        error
    end
  end

  defp rearm_active_cron_schedule_after_reset(repo, cron_schedule_id, now) do
    case Store.lock_cron_schedule(repo, cron_schedule_id) do
      %CronSchedule{status: "active"} = schedule ->
        with {:ok, next_fire_at} <-
               Planner.next_fire_after(schedule.schedule, schedule.timezone, now),
             {:ok, schedule} <-
               schedule
               |> CronSchedule.changeset(%{next_fire_at: next_fire_at})
               |> repo.update(),
             {:ok, _event_result} <- arm_cron_fire_in_tx(repo, schedule, next_fire_at, now, []) do
          {:ok, :rearmed}
        end

      %CronSchedule{} ->
        {:ok, :skipped}

      nil ->
        {:ok, :missing}
    end
  end
end
