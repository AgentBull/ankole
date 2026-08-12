defmodule Ankole.Schedule.Cron do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AutomationJobs
  alias Ankole.Repo
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Delivery
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

    with {:ok, attrs} <- Normalizer.cron_schedule_attrs(attrs, now, opts) do
      Repo.transact(fn repo ->
        with :ok <-
               AutomationJobs.validate_bindable_in_tx(
                 repo,
                 attrs.automation_job_id,
                 attrs.agent_uid,
                 now
               ) do
          insert_cron_schedule_in_tx(repo, attrs, now, opts)
        end
      end)
    end
  end

  @spec reconcile_cron_schedules(keyword()) ::
          {:ok, %{reconciled: non_neg_integer()}} | {:error, term()}
  def reconcile_cron_schedules(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    schedule_ids =
      CronSchedule
      |> select([schedule], schedule.id)
      |> Repo.all()

    Enum.reduce_while(schedule_ids, {:ok, 0}, fn schedule_id, {:ok, count} ->
      result =
        Repo.transact(fn repo ->
          case Store.lock_cron_schedule(repo, schedule_id) do
            %CronSchedule{} = schedule ->
              reconcile_locked_schedule_in_tx(repo, schedule, now, opts)

            nil ->
              {:ok, nil}
          end
        end)

      case result do
        {:ok, _schedule} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, {schedule_id, reason}}}
      end
    end)
    |> case do
      {:ok, count} -> {:ok, %{reconciled: count}}
      {:error, _reason} = error -> error
    end
  end

  @spec update_cron_schedule(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def update_cron_schedule(cron_schedule_id, attrs, opts \\ [])
      when is_binary(cron_schedule_id) and is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
           :ok <- Store.reject_terminal(schedule),
           {:ok, attrs} <- Normalizer.cron_schedule_update_attrs(schedule, attrs, now, opts),
           :ok <-
             validate_updated_automation_job(repo, schedule, attrs, now),
           changeset = CronSchedule.changeset(schedule, attrs),
           recurrence_changed? =
             Ecto.Changeset.changed?(changeset, :schedule) or
               Ecto.Changeset.changed?(changeset, :timezone),
           {:ok, schedule} <- repo.update(changeset),
           {:ok, schedule} <-
             sync_after_update_in_tx(repo, schedule, recurrence_changed?, now, opts) do
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
           :ok <- Store.reject_terminal(schedule),
           {:ok, schedule} <- put_schedule_status(repo, schedule, "paused"),
           {:ok, schedule} <- sync_next_event_in_tx(repo, schedule, nil, now, opts) do
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
      case Store.lock_cron_schedule(repo, cron_schedule_id) do
        %CronSchedule{status: "paused"} = schedule ->
          with {:ok, next_fire_at} <-
                 Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
            # A bound that ran out while the schedule was paused makes resume
            # complete it: that is the schedule's true state, not an error.
            if bound_spent?(repo, schedule, next_fire_at) do
              complete_schedule_in_tx(repo, schedule, now, opts)
            else
              with {:ok, schedule} <- put_schedule_status(repo, schedule, "active") do
                sync_next_event_in_tx(repo, schedule, next_fire_at, now, opts)
              end
            end
          end

        %CronSchedule{status: "active"} = schedule ->
          with :ok <- assert_recurring_invariant_in_tx(repo, schedule) do
            {:ok, schedule}
          end

        %CronSchedule{status: "completed"} ->
          {:error, :cron_schedule_completed}

        %CronSchedule{status: "deleted"} ->
          {:error, :cron_schedule_deleted}

        nil ->
          {:error, :cron_schedule_not_found}
      end
    end)
  end

  @spec remove_cron_schedule(Ecto.UUID.t(), keyword()) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def remove_cron_schedule(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, cron_schedule_id),
           {:ok, schedule} <- put_schedule_status(repo, schedule, "deleted"),
           {:ok, schedule} <- sync_next_event_in_tx(repo, schedule, nil, now, opts),
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
           :ok <- Store.reject_terminal(schedule),
           {:ok, request_id} <- manual_request_id(opts),
           {:ok, result} <- arm_manual_cron_fire_in_tx(repo, schedule, request_id, now, opts) do
        {:ok, result}
      else
        nil -> {:error, :cron_schedule_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec validate_fire_schedule(CronSchedule.t(), ScheduledEvent.t()) ::
          :ok | {:cancel, :cron_schedule_not_active}
  def validate_fire_schedule(%CronSchedule{status: status}, %ScheduledEvent{} = event) do
    case {event_trigger(event), status} do
      {"scheduled", "active"} -> :ok
      {"manual", status} when status in ["active", "paused"] -> :ok
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
               |> CronSchedule.changeset(%{last_fire_at: event.cron_fire_slot_at})
               |> repo.update() do
          advance_within_bound(repo, schedule, next_fire_at, now, opts)
        end
    end
  end

  @spec advance_after_terminal_failure(
          module(),
          CronSchedule.t(),
          ScheduledEvent.t(),
          DateTime.t(),
          keyword()
        ) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def advance_after_terminal_failure(
        repo,
        %CronSchedule{status: "active"} = schedule,
        %ScheduledEvent{} = event,
        now,
        opts
      ) do
    case event_trigger(event) do
      "scheduled" ->
        with {:ok, next_fire_at} <-
               Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
          advance_within_bound(repo, schedule, next_fire_at, now, opts)
        end

      "manual" ->
        {:ok, schedule}
    end
  end

  def advance_after_terminal_failure(
        _repo,
        %CronSchedule{} = schedule,
        _event,
        _now,
        _opts
      ),
      do: {:ok, schedule}

  # Arms the next slot, or completes the schedule when the occurrence bound is
  # spent. The bound counts due slots, so the check runs after the current
  # slot's event row reached a consumed status.
  defp advance_within_bound(
         repo,
         %CronSchedule{} = schedule,
         %DateTime{} = next_fire_at,
         now,
         opts
       ) do
    if bound_spent?(repo, schedule, next_fire_at) do
      complete_schedule_in_tx(repo, schedule, now, opts)
    else
      sync_next_event_in_tx(repo, schedule, next_fire_at, now, opts)
    end
  end

  # Whether the recurrence must not arm the next slot: the count budget is used
  # up by consumed slots, or the next occurrence falls past the inclusive
  # cutoff. Unbounded schedules never spend out.
  defp bound_spent?(repo, %CronSchedule{} = schedule, %DateTime{} = next_fire_at) do
    case Planner.occurrences_bound(schedule.schedule) do
      {:count, count} -> Store.count_consumed_cron_slots(repo, schedule.id) >= count
      {:until, until} -> DateTime.compare(next_fire_at, until) == :gt
      nil -> false
    end
  end

  defp complete_schedule_in_tx(repo, schedule, now, opts) do
    with {:ok, schedule} <- put_schedule_status(repo, schedule, "completed") do
      sync_next_event_in_tx(repo, schedule, nil, now, opts)
    end
  end

  @spec sync_next_event_in_tx(
          module(),
          CronSchedule.t(),
          DateTime.t() | nil,
          DateTime.t(),
          keyword()
        ) ::
          {:ok, CronSchedule.t()} | {:error, term()}
  def sync_next_event_in_tx(repo, %CronSchedule{} = schedule, desired_slot, now, opts) do
    live_events = Store.lock_live_recurring_cron_events(repo, schedule.id)

    with :ok <- reject_multiple_live_events(live_events),
         {:ok, schedule} <- put_next_fire_at(repo, schedule, desired_slot),
         {:ok, _event} <-
           sync_live_event_in_tx(repo, schedule, live_events, desired_slot, now, opts),
         :ok <- assert_recurring_invariant_in_tx(repo, schedule) do
      {:ok, schedule}
    end
  end

  @spec assert_recurring_invariant_in_tx(module(), CronSchedule.t()) ::
          :ok | {:error, term()}
  def assert_recurring_invariant_in_tx(repo, %CronSchedule{} = schedule) do
    live_events = Store.lock_live_recurring_cron_events(repo, schedule.id)

    case {schedule.status, schedule.next_fire_at, live_events} do
      {"active", %DateTime{} = next_fire_at,
       [
         %ScheduledEvent{
           status: "scheduled",
           cron_fire_slot_at: %DateTime{} = slot_at,
           due_at: %DateTime{} = due_at
         }
       ]} ->
        if same_datetime?(slot_at, next_fire_at) and same_datetime?(due_at, next_fire_at),
          do: :ok,
          else: {:error, :cron_schedule_invariant_broken}

      {status, nil, []} when status in ["paused", "deleted", "completed"] ->
        :ok

      _state ->
        {:error, :cron_schedule_invariant_broken}
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
         {:ok, persisted} <- Store.lock_cron_by_idempotency(repo, attrs),
         {:ok, persisted} <- reconcile_locked_schedule_in_tx(repo, persisted, now, opts) do
      status = if attempted.id == persisted.id, do: :created, else: :already_exists
      {:ok, %{status: status, cron_schedule: persisted}}
    end
  end

  defp reconcile_locked_schedule_in_tx(
         repo,
         %CronSchedule{status: "active"} = schedule,
         now,
         opts
       ) do
    case Store.lock_live_recurring_cron_events(repo, schedule.id) do
      [%ScheduledEvent{cron_fire_slot_at: %DateTime{} = slot_at}] ->
        sync_next_event_in_tx(repo, schedule, slot_at, now, opts)

      [] ->
        # Reconcile heals an active schedule with no armed slot; a spent bound
        # means the correct healed state is completed, not a new slot.
        with {:ok, next_fire_at} <-
               Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
          advance_within_bound(repo, schedule, next_fire_at, now, opts)
        end

      events ->
        {:error, {:multiple_live_cron_events, Enum.map(events, & &1.id)}}
    end
  end

  defp reconcile_locked_schedule_in_tx(repo, %CronSchedule{} = schedule, now, opts) do
    sync_next_event_in_tx(repo, schedule, nil, now, opts)
  end

  defp sync_after_update_in_tx(
         repo,
         %CronSchedule{status: "active"} = schedule,
         true,
         now,
         opts
       ) do
    with {:ok, next_fire_at} <-
           Planner.next_fire_after(schedule.schedule, schedule.timezone, now) do
      # An update that leaves no occurrence to run is a caller error: the new
      # bound is below the already-consumed slots or before the next fire.
      if bound_spent?(repo, schedule, next_fire_at) do
        {:error, :schedule_occurrences_exhausted}
      else
        sync_next_event_in_tx(repo, schedule, next_fire_at, now, opts)
      end
    end
  end

  defp sync_after_update_in_tx(repo, %CronSchedule{} = schedule, false, now, opts) do
    reconcile_locked_schedule_in_tx(repo, schedule, now, opts)
  end

  defp sync_after_update_in_tx(repo, %CronSchedule{} = schedule, true, now, opts) do
    sync_next_event_in_tx(repo, schedule, nil, now, opts)
  end

  defp sync_live_event_in_tx(_repo, _schedule, [], nil, _now, _opts), do: {:ok, nil}

  defp sync_live_event_in_tx(repo, _schedule, [event], nil, now, _opts) do
    cancel_event(repo, event, now, "cron_schedule_changed")
  end

  defp sync_live_event_in_tx(repo, schedule, [], %DateTime{} = slot_at, now, opts) do
    arm_scheduled_cron_fire_in_tx(repo, schedule, slot_at, now, opts)
    |> event_from_arm_result()
  end

  defp sync_live_event_in_tx(
         repo,
         schedule,
         [%ScheduledEvent{cron_fire_slot_at: %DateTime{} = current_slot} = event],
         %DateTime{} = desired_slot,
         now,
         opts
       ) do
    case same_datetime?(current_slot, desired_slot) do
      true ->
        update_scheduled_event_snapshot(repo, event, schedule, desired_slot)

      false ->
        with {:ok, _cancelled} <-
               cancel_event(repo, event, now, "cron_schedule_changed"),
             {:ok, result} <-
               arm_scheduled_cron_fire_in_tx(repo, schedule, desired_slot, now, opts) do
          {:ok, result.scheduled_event}
        end
    end
  end

  defp arm_scheduled_cron_fire_in_tx(repo, schedule, slot_at, now, opts) do
    schedule
    |> event_attrs(
      slot_at,
      slot_at,
      now,
      "scheduled",
      Store.cron_arm_idempotency_key(schedule.id, slot_at),
      nil
    )
    |> then(&Store.insert_event_and_wake_in_tx(repo, &1, opts))
  end

  defp arm_manual_cron_fire_in_tx(repo, schedule, request_id, now, opts) do
    schedule
    |> event_attrs(
      now,
      now,
      now,
      "manual",
      Store.cron_manual_idempotency_key(schedule.id, request_id),
      request_id
    )
    |> then(&Store.insert_idempotent_event_and_wake_in_tx(repo, &1, opts))
  end

  defp event_attrs(schedule, slot_at, due_at, now, trigger, idempotency_key, tool_call_id) do
    delivery = schedule.delivery || %{}
    {:ok, primary_target} = Delivery.primary_target(delivery, schedule.binding_name)

    %{
      kind: "cron_fire",
      status: "scheduled",
      agent_uid: schedule.agent_uid,
      session_id: schedule.session_id,
      binding_name: schedule.binding_name,
      signal_channel_id: primary_target["signal_channel_id"],
      provider_thread_id: primary_target["provider_thread_id"],
      due_at: due_at,
      timezone: schedule.timezone,
      requested_at: now,
      idempotency_key: idempotency_key,
      tool_call_id: tool_call_id,
      cron_schedule_id: schedule.id,
      automation_job_id: schedule.automation_job_id,
      cron_fire_slot_at: slot_at,
      origin_ai_message_id: Attrs.map_text(schedule.created_by || %{}, "origin_ai_message_id"),
      source_provenance: %{
        "cron_schedule_id" => schedule.id,
        "trigger" => trigger
      },
      wake_payload: wake_payload(schedule, slot_at, due_at, trigger),
      last_fire_error: %{}
    }
  end

  defp update_scheduled_event_snapshot(repo, event, schedule, slot_at) do
    delivery = schedule.delivery || %{}
    {:ok, primary_target} = Delivery.primary_target(delivery, schedule.binding_name)

    event
    |> ScheduledEvent.changeset(%{
      binding_name: schedule.binding_name,
      automation_job_id: schedule.automation_job_id,
      signal_channel_id: primary_target["signal_channel_id"],
      provider_thread_id: primary_target["provider_thread_id"],
      due_at: slot_at,
      timezone: schedule.timezone,
      origin_ai_message_id: Attrs.map_text(schedule.created_by || %{}, "origin_ai_message_id"),
      source_provenance: %{
        "cron_schedule_id" => schedule.id,
        "trigger" => "scheduled"
      },
      wake_payload: wake_payload(schedule, slot_at, slot_at, "scheduled")
    })
    |> repo.update()
  end

  defp wake_payload(schedule, slot_at, due_at, trigger) do
    %{
      "trigger" => trigger,
      "cron_schedule_id" => schedule.id,
      "cron_schedule_name" => schedule.name,
      "cron_fire_slot_at" => DateTime.to_iso8601(slot_at),
      "due_at" => DateTime.to_iso8601(due_at),
      "timezone" => schedule.timezone,
      "payload" => schedule.payload || %{},
      "delivery" => schedule.delivery || %{}
    }
  end

  defp cancel_event(repo, event, now, reason) do
    event
    |> ScheduledEvent.changeset(%{
      status: "cancelled",
      cancelled_at: now,
      last_fire_error: %{"reason" => reason}
    })
    |> repo.update()
  end

  defp put_schedule_status(_repo, %CronSchedule{status: status} = schedule, status),
    do: {:ok, schedule}

  defp put_schedule_status(repo, schedule, status) do
    schedule
    |> CronSchedule.changeset(%{status: status})
    |> repo.update()
  end

  defp put_next_fire_at(_repo, %CronSchedule{next_fire_at: nil} = schedule, nil),
    do: {:ok, schedule}

  defp put_next_fire_at(repo, schedule, nil) do
    schedule
    |> CronSchedule.changeset(%{next_fire_at: nil})
    |> repo.update()
  end

  defp put_next_fire_at(repo, schedule, %DateTime{} = next_fire_at) do
    case schedule.next_fire_at do
      %DateTime{} = current ->
        if same_datetime?(current, next_fire_at) do
          {:ok, schedule}
        else
          schedule
          |> CronSchedule.changeset(%{next_fire_at: next_fire_at})
          |> repo.update()
        end

      _current ->
        schedule
        |> CronSchedule.changeset(%{next_fire_at: next_fire_at})
        |> repo.update()
    end
  end

  defp manual_request_id(opts) do
    case Keyword.get(opts, :tool_call_id) || Keyword.get(opts, :idempotency_key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_text, :tool_call_id}}
          request_id -> {:ok, request_id}
        end

      _value ->
        {:error, {:missing_text, :tool_call_id}}
    end
  end

  defp reject_multiple_live_events(events) when length(events) <= 1, do: :ok

  defp reject_multiple_live_events(events),
    do: {:error, {:multiple_live_cron_events, Enum.map(events, & &1.id)}}

  defp event_from_arm_result({:ok, %{scheduled_event: event}}), do: {:ok, event}
  defp event_from_arm_result({:error, _reason} = error), do: error

  defp event_trigger(%ScheduledEvent{} = event) do
    get_in(event.wake_payload || %{}, ["trigger"]) || "scheduled"
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(left, right) == :eq
  end

  defp validate_updated_automation_job(repo, schedule, attrs, now) do
    if Map.has_key?(attrs, :automation_job_id) do
      AutomationJobs.validate_bindable_in_tx(
        repo,
        attrs.automation_job_id,
        schedule.agent_uid,
        now
      )
    else
      :ok
    end
  end
end
