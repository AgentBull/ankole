defmodule Ankole.Schedule.Fire do
  @moduledoc false

  require Ash.Query

  alias Ankole.Repo
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Cron
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store
  alias Ankole.Schedule.Jobs.FireCron

  def prepare_event(id, opts) do
    case Store.get_scheduled_event(id) do
      nil -> {:ok, nil}
      event -> prepare_delivery(event, Keyword.get(opts, :now, DateTime.utc_now(:microsecond)))
    end
  end

  def prepare_cron(id, now) do
    case Store.get_cron_schedule(id) do
      %CronSchedule{status: :active, next_fire_at: %DateTime{}} = schedule ->
        result =
          with {:ok, attrs} <-
                 Cron.event_attrs(
                   schedule,
                   schedule.next_fire_at,
                   schedule.next_fire_at,
                   now,
                   "scheduled",
                   Store.cron_fire_idempotency_key(id, schedule.next_fire_at),
                   nil
                 ),
               do:
                 prepare_delivery(
                   struct(ScheduledEvent, Map.put(attrs, :id, Store.reserve_event_id())),
                   now
                 )

        case result do
          {:error, reason} -> {:error, {:cron_fire_failed, reason, schedule.next_fire_at}}
          {:ok, plan} -> {:ok, Map.put(plan, :schedule_snapshot, schedule)}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp prepare_delivery(event, now) do
    Ankole.Signals.prepare_dispatch(
      Ankole.Signals.source_reference(event),
      signal_payload(event, now),
      authorization: Ankole.Principals.WorkAccess.fields(event),
      reply_route: %{
        binding_name: event.binding_name,
        conversation_id: event.conversation_id,
        provider_thread_id: event.provider_thread_id,
        provider_message_id: event.provider_message_id
      }
    )
  end

  @spec fire_due_event_in_tx(pos_integer(), keyword()) ::
          {:ok, %{status: :fired | :noop | :cancelled, scheduled_event: ScheduledEvent.t() | nil}}
          | {:error, term()}
  def fire_due_event_in_tx(scheduled_event_id, opts)
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, plan} <- dispatch_plan(scheduled_event_id, opts),
         {:ok, _} <- lock_delivery(plan, Store.get_scheduled_event(scheduled_event_id)),
         {:ok, authorized} <- authorize_fire_in_tx(scheduled_event_id, now),
         {:ok, event, schedule} <-
           claim_due_event_with_schedule_in_tx(scheduled_event_id, now),
         true <- fire_authorization(event) == fire_authorization(authorized),
         {:ok, result} <-
           fire_claimed_event_in_tx(event, schedule, now, Keyword.put(opts, :dispatch, plan)) do
      {:ok, result}
    else
      false -> {:error, :scheduled_event_changed}
      :noop -> {:ok, %{status: :noop, scheduled_event: nil}}
      {:error, _reason} = error -> error
    end
  end

  @spec fire_cron_in_tx(Ecto.UUID.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def fire_cron_in_tx(cron_schedule_id, now, plan \\ nil) when is_binary(cron_schedule_id) do
    case Store.get_cron_schedule(cron_schedule_id) do
      %CronSchedule{status: :active} = schedule ->
        result =
          with {:ok, plan} <- if(plan, do: {:ok, plan}, else: prepare_cron(cron_schedule_id, now)),
               {:ok, _} <- lock_delivery(plan, schedule),
               do: fire_active_cron_in_tx(schedule, now, plan)

        case result do
          {:error, {:cron_fire_failed, _, _}} = error -> error
          {:error, reason} -> {:error, {:cron_fire_failed, reason, schedule.next_fire_at}}
          result -> result
        end

      _schedule ->
        {:ok, %{status: :noop, scheduled_event: nil}}
    end
  end

  defp fire_active_cron_in_tx(schedule, now, plan) do
    if DateTime.after?(schedule.next_fire_at, now) do
      with :ok <-
             Ankole.Job.schedule_in_tx(
               FireCron,
               %{"cron_schedule_id" => schedule.id},
               schedule.next_fire_at
             ) do
        {:ok, %{status: :noop, scheduled_event: nil}}
      end
    else
      with :ok <- authorize_work_in_tx(schedule),
           %CronSchedule{} = locked <-
             Store.lock_cron_schedule(schedule.id, :prepared),
           true <- same_cron_fire?(locked, plan.schedule_snapshot) do
        fire_locked_cron_in_tx(locked, now, plan)
      else
        false -> {:error, :cron_schedule_changed}
        nil -> {:error, :cron_schedule_changed}
        {:error, _reason} = error -> error
      end
    end
  end

  defp same_cron_fire?(locked, snapshot) do
    locked.status == :active and locked.updated_at == snapshot.updated_at and
      locked.next_fire_at == snapshot.next_fire_at
  end

  defp fire_locked_cron_in_tx(schedule, now, plan) do
    case if(Ankole.AutomationJobs.JobSources.live?(schedule),
           do: Cron.validate_fire_schedule(schedule),
           else: {:cancel, :page_trashed}
         ) do
      :ok ->
        with {:ok, event} <-
               insert_cron_history(
                 schedule,
                 now,
                 :fired,
                 nil,
                 plan.signal["data"]["scheduled_event_id"]
               ),
             {:ok, delivery} <- deliver_scheduled_event(event, now, plan),
             {:ok, event} <- mark_event_fired(event, delivery, now),
             :ok <- Ankole.Issues.track_fire_in_tx(schedule),
             {:ok, _schedule} <-
               Cron.advance_after_fire(schedule, event.cron_fire_slot_at, now) do
          {:ok, fire_result(event, delivery)}
        end

      {:cancel, reason} ->
        with {:ok, event} <- insert_cron_history(schedule, now, :cancelled, reason),
             {:ok, _schedule} <- Cron.advance_after_terminal_failure(schedule, now) do
          {:ok, %{status: :cancelled, scheduled_event: event}}
        end
    end
  end

  defp insert_cron_history(schedule, now, status, reason, reserved_id \\ nil) do
    key = Store.cron_fire_idempotency_key(schedule.id, schedule.next_fire_at)

    attrs_result =
      if status == :cancelled do
        # A cancelled legacy rule can have no valid delivery target. It cannot
        # produce work; its history retains the stored delivery in wake_payload.
        {:ok,
         Cron.event_attrs(
           schedule,
           %{},
           schedule.next_fire_at,
           schedule.next_fire_at,
           now,
           "scheduled",
           key,
           nil
         )}
      else
        Cron.event_attrs(
          schedule,
          schedule.next_fire_at,
          schedule.next_fire_at,
          now,
          "scheduled",
          key,
          nil
        )
      end

    with {:ok, attrs} <- attrs_result do
      attrs = if reserved_id, do: Map.put(attrs, :id, reserved_id), else: attrs

      case status do
        :cancelled ->
          attrs =
            Map.merge(attrs, %{cancelled_at: now, last_fire_error: %{"reason" => inspect(reason)}})

          Store.create_event(attrs, :record_cancelled)

        :fired ->
          Store.create_event(attrs)

        :failed ->
          with {:ok, event} <- Store.create_event(attrs) do
            Ankole.Ash.update(event, :fail, %{last_fire_error: %{"reason" => inspect(reason)}})
          end
      end
    end
  end

  @doc """
  Records the terminal failure of a cron fire after its transaction rolls back.

  A failure before the last attempt keeps the slot for the next attempt.
  """
  def persist_cron_error({:error, {:cron_fire_failed, reason, slot}}, id, now, opts) do
    result =
      if terminal_fire_failure?(opts) do
        Repo.transact_top_level(fn ->
          record_fire_failure_in_tx(id, slot, reason, now)
        end)
      else
        {:ok, nil}
      end

    case result do
      {:ok, _schedule} ->
        {:error, reason}

      {:error, persistence_reason} ->
        {:error, {:fire_error_persistence_failed, reason, persistence_reason}}
    end
  end

  def persist_cron_error(result, _id, _now, _opts), do: result

  @doc false
  def record_fire_failure_in_tx(id, slot, reason, now) do
    case Store.lock_cron_schedule(id) do
      %CronSchedule{status: :active, next_fire_at: %DateTime{} = next_fire_at} = schedule ->
        if DateTime.compare(next_fire_at, slot) == :eq do
          with {:ok, _event} <- insert_cron_history(schedule, now, :failed, reason) do
            Cron.advance_after_terminal_failure(schedule, now)
          end
        else
          {:ok, nil}
        end

      {:error, _reason} = error ->
        error

      _schedule ->
        {:ok, nil}
    end
  end

  defp authorize_fire_in_tx(id, now) do
    case Store.get_scheduled_event(id) do
      %ScheduledEvent{status: :scheduled} = event ->
        authorize_scheduled_event_in_tx(event, now)

      _ ->
        :noop
    end
  end

  # Only a due, unclaimed event admits new work. Terminal and future events are noops.
  defp authorize_scheduled_event_in_tx(event, now) do
    if DateTime.compare(event.due_at, now) == :gt do
      :noop
    else
      with :ok <- authorize_work_in_tx(event), do: {:ok, event}
    end
  end

  defp authorize_work_in_tx(work), do: Ankole.Principals.WorkAccess.check_in_tx(work)

  defp dispatch_plan(id, opts) do
    case Keyword.fetch(opts, :dispatch) do
      {:ok, plan} -> {:ok, plan}
      :error -> prepare_event(id, opts)
    end
  end

  defp lock_delivery(nil, _work), do: {:ok, nil}
  defp lock_delivery(plan, work), do: Ankole.Signals.lock_dispatch_in_tx(plan, List.wrap(work))

  defp fire_authorization(work) do
    Map.take(work, [:authorization_kind, :human_uid, :human_access_version])
  end

  defp claim_due_event_with_schedule_in_tx(scheduled_event_id, now) do
    case Store.get_scheduled_event(scheduled_event_id) do
      %ScheduledEvent{kind: "cron_fire", cron_schedule_id: cron_schedule_id}
      when is_binary(cron_schedule_id) ->
        schedule = Store.lock_cron_schedule(cron_schedule_id, :prepared)

        case claim_due_event_in_tx(scheduled_event_id, now) do
          {:ok, event} -> {:ok, event, schedule}
          :noop -> :noop
        end

      %ScheduledEvent{} ->
        case claim_due_event_in_tx(scheduled_event_id, now) do
          {:ok, event} -> {:ok, event, nil}
          :noop -> :noop
        end

      nil ->
        :noop
    end
  end

  defp claim_due_event_in_tx(scheduled_event_id, now) do
    ScheduledEvent
    |> Ash.Query.filter(id == ^scheduled_event_id and status == :scheduled and due_at <= ^now)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one(lock_identity: {"scheduled_events", scheduled_event_id})
    |> case do
      {:ok, %ScheduledEvent{} = event} -> {:ok, event}
      {:ok, nil} -> :noop
    end
  end

  defp fire_claimed_event_in_tx(
         %ScheduledEvent{kind: "check_back_later"} = event,
         _schedule,
         now,
         opts
       ) do
    with {:ok, delivery} <- deliver_scheduled_event(event, now, opts[:dispatch]),
         {:ok, event} <- mark_event_fired(event, delivery, now) do
      {:ok, fire_result(event, delivery)}
    end
  end

  defp fire_claimed_event_in_tx(
         %ScheduledEvent{kind: "cron_fire"} = event,
         schedule,
         now,
         opts
       ) do
    with %CronSchedule{} = schedule <- schedule,
         true <- Ankole.AutomationJobs.JobSources.live?(schedule),
         :ok <- Cron.validate_fire_schedule(schedule),
         {:ok, delivery} <- deliver_scheduled_event(event, now, opts[:dispatch]),
         {:ok, event} <- mark_event_fired(event, delivery, now),
         :ok <- Ankole.Issues.track_fire_in_tx(schedule) do
      {:ok, fire_result(event, delivery)}
    else
      false -> mark_event_cancelled(event, now, :page_trashed)
      nil -> mark_event_cancelled(event, now, :cron_schedule_not_found)
      {:cancel, reason} -> mark_event_cancelled(event, now, reason)
      {:error, _reason} = error -> error
    end
  end

  defp deliver_scheduled_event(event, now, plan) do
    expected = signal_payload(event, now) |> Map.delete("source")
    prepared = Map.take(plan.signal, Map.keys(expected))

    if expected == prepared,
      do: Ankole.Signals.deliver_dispatch_in_tx(plan),
      else: {:error, :scheduled_event_changed}
  end

  defp mark_event_fired(event, delivery, now) do
    Ankole.Ash.update(event, :fire, %{
      signal_id: delivery.signal_id,
      fired_at: now,
      last_fire_error: %{}
    })
  end

  defp fire_result(event, delivery) do
    run = Enum.find_value(delivery.receipts, & &1.automation_job_run_id)
    run = if run, do: Ankole.AutomationJobs.get_run_record(run)

    %{
      status: :fired,
      scheduled_event: event,
      signal: List.first(delivery.signals),
      signals: delivery.signals,
      automation_job_run: run,
      deliveries: delivery.receipts
    }
  end

  defp mark_event_cancelled(%ScheduledEvent{} = event, now, reason) do
    with {:ok, event} <-
           Ankole.Ash.update(event, :cancel, %{
             cancelled_at: now,
             last_fire_error: %{"reason" => inspect(reason)}
           }) do
      {:ok, %{status: :cancelled, scheduled_event: event}}
    end
  end

  defp signal_type(%ScheduledEvent{kind: "check_back_later"}), do: "check_back_later.wakeup"
  defp signal_type(%ScheduledEvent{kind: "cron_fire"}), do: "cron.fire"

  defp source_event_id(%ScheduledEvent{kind: "check_back_later", id: id}),
    do: "check_back_later:#{id}:wakeup"

  defp source_event_id(
         %ScheduledEvent{
           kind: "cron_fire",
           cron_schedule_id: cron_schedule_id,
           cron_fire_slot_at: %DateTime{} = slot_at
         } = event
       ) do
    case get_in(event.wake_payload || %{}, ["trigger"]) || "scheduled" do
      "manual" -> event.idempotency_key
      "scheduled" -> Store.cron_source_event_id(cron_schedule_id, slot_at)
    end
  end

  defp signal_payload(%ScheduledEvent{} = event, now) do
    %{
      "specversion" => "1.0",
      "id" => source_event_id(event),
      "source" => "control-plane://schedule/#{event.kind}",
      "subject" => "schedule:#{event.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => signal_type(event),
      "data" =>
        Map.merge(get_in(event.wake_payload || %{}, ["payload"]) || %{}, %{
          "trigger" => event.wake_payload["trigger"],
          "cron_schedule_name" => event.wake_payload["cron_schedule_name"],
          "scheduled_event_id" => event.id,
          "due_at" => DateTime.to_iso8601(event.due_at),
          "fired_at" => DateTime.to_iso8601(now),
          "timezone" => event.timezone,
          "cron_schedule_id" => event.cron_schedule_id,
          "cron_fire_slot_at" => Planner.datetime(event.cron_fire_slot_at),
          "wake_payload" => event.wake_payload || %{},
          "reply_route" =>
            Attrs.reject_nil_values(%{
              "binding_name" => event.binding_name,
              "conversation_id" => event.conversation_id,
              "provider_thread_id" => event.provider_thread_id,
              "provider_message_id" => event.provider_message_id
            })
        })
    }
  end

  @doc "Records the error of a failed fire after its transaction rolls back."
  def persist_fire_error({:error, reason} = error, scheduled_event_id, opts) do
    terminal? = terminal_fire_failure?(opts)

    case Repo.transact_top_level(fn ->
           record_fire_error_in_tx(scheduled_event_id, reason, terminal?)
         end) do
      {:ok, _event} ->
        error

      {:error, persistence_reason} ->
        {:error, {:fire_error_persistence_failed, reason, persistence_reason}}
    end
  end

  def persist_fire_error(result, _scheduled_event_id, _opts), do: result

  @doc false
  def record_fire_error_in_tx(scheduled_event_id, reason, terminal?) do
    case Store.lock_scheduled_event(scheduled_event_id) do
      %ScheduledEvent{status: :scheduled} = event ->
        action = if terminal?, do: :fail, else: :record_error
        Ankole.Ash.update(event, action, %{last_fire_error: %{"reason" => inspect(reason)}})

      %ScheduledEvent{} = event ->
        {:ok, event}

      nil ->
        {:ok, nil}
    end
  end

  defp terminal_fire_failure?(opts) do
    case {Keyword.get(opts, :attempt), Keyword.get(opts, :max_attempts)} do
      {attempt, max_attempts}
      when is_integer(attempt) and is_integer(max_attempts) and max_attempts > 0 ->
        attempt >= max_attempts

      _value ->
        false
    end
  end
end
