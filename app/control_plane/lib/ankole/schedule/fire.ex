defmodule Ankole.Schedule.Fire do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Schemas.Run, as: AutomationJobRun
  alias Ankole.SignalsGateway
  alias Ankole.Repo
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Cron
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store

  @spec fire_due_event(pos_integer(), keyword()) ::
          {:ok, %{status: :fired | :noop | :cancelled, scheduled_event: ScheduledEvent.t() | nil}}
          | {:error, term()}
  def fire_due_event(scheduled_event_id, opts \\ [])
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, event, schedule} <-
             claim_due_event_with_schedule_in_tx(repo, scheduled_event_id, now),
           {:ok, result} <- fire_claimed_event_in_tx(repo, event, schedule, now, opts) do
        {:ok, result}
      else
        :noop -> {:ok, %{status: :noop, scheduled_event: nil}}
        {:error, _reason} = error -> error
      end
    end)
    |> persist_fire_error(scheduled_event_id, opts)
  end

  defp claim_due_event_with_schedule_in_tx(repo, scheduled_event_id, now) do
    case repo.get(ScheduledEvent, scheduled_event_id) do
      %ScheduledEvent{kind: "cron_fire", cron_schedule_id: cron_schedule_id}
      when is_binary(cron_schedule_id) ->
        schedule = Store.lock_cron_schedule(repo, cron_schedule_id)

        case claim_due_event_in_tx(repo, scheduled_event_id, now) do
          {:ok, event} -> {:ok, event, schedule}
          :noop -> :noop
        end

      %ScheduledEvent{} ->
        case claim_due_event_in_tx(repo, scheduled_event_id, now) do
          {:ok, event} -> {:ok, event, nil}
          :noop -> :noop
        end

      nil ->
        :noop
    end
  end

  defp claim_due_event_in_tx(repo, scheduled_event_id, now) do
    query =
      ScheduledEvent
      |> where([event], event.id == ^scheduled_event_id)
      |> where([event], event.status == "scheduled")
      |> where([event], event.due_at <= ^now)

    {count, _rows} =
      repo.update_all(query,
        inc: [fire_attempts: 1],
        set: [status: "firing", fire_claimed_at: now, updated_at: now]
      )

    case count do
      1 -> {:ok, repo.get!(ScheduledEvent, scheduled_event_id)}
      _other -> :noop
    end
  end

  defp fire_claimed_event_in_tx(
         repo,
         %ScheduledEvent{kind: "check_back_later"} = event,
         _schedule,
         now,
         _opts
       ) do
    with {:ok, delivery} <- deliver_scheduled_event(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, delivery, now) do
      {:ok, fire_result(event, delivery)}
    end
  end

  defp fire_claimed_event_in_tx(
         repo,
         %ScheduledEvent{kind: "cron_fire"} = event,
         schedule,
         now,
         opts
       ) do
    with %CronSchedule{} = schedule <- schedule,
         :ok <- Cron.validate_fire_schedule(schedule, event),
         {:ok, delivery} <- deliver_scheduled_event(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, delivery, now),
         {:ok, _schedule} <- Cron.advance_after_fire(repo, schedule, event, now, opts) do
      {:ok, fire_result(event, delivery)}
    else
      nil -> mark_event_cancelled(repo, event, now, :cron_schedule_not_found)
      {:cancel, reason} -> mark_event_cancelled(repo, event, now, reason)
      {:error, _reason} = error -> error
    end
  end

  defp append_scheduled_actor_event(repo, %ScheduledEvent{} = event, now) do
    SignalsGateway.append_actor_event_in_tx(repo, %{
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      session_id: event.session_id,
      source_event_id: source_event_id(event),
      signal_channel_id: event.signal_channel_id,
      provider_thread_id: event.provider_thread_id,
      source_entry_id: event.source_entry_id,
      type: actor_event_type(event),
      available_at: now,
      sender_key: nil,
      payload: actor_event_payload(event, now)
    })
  end

  defp deliver_scheduled_event(
         repo,
         %ScheduledEvent{automation_job_id: nil} = event,
         now
       ) do
    with {:ok, actor_event} <- append_scheduled_actor_event(repo, event, now) do
      {:ok, {:actor_event, actor_event}}
    end
  end

  defp deliver_scheduled_event(
         repo,
         %ScheduledEvent{automation_job_id: automation_job_id} = event,
         now
       ) do
    with {:ok, %{automation_job_run: run}} <-
           AutomationJobs.enqueue_run_in_tx(
             repo,
             automation_job_id,
             event.agent_uid,
             actor_event_payload(event, now),
             now: now
           ) do
      {:ok, {:automation_job_run, run}}
    end
  end

  defp mark_event_fired(
         repo,
         %ScheduledEvent{} = event,
         {:actor_event, %{id: actor_event_id}},
         now
       ) do
    event
    |> ScheduledEvent.changeset(%{
      status: "fired",
      # Source table: actor_event_id stores actor_events.id appended for this fire.
      actor_event_id: actor_event_id,
      fired_at: now,
      last_fire_error: %{}
    })
    |> repo.update()
  end

  defp mark_event_fired(
         repo,
         %ScheduledEvent{} = event,
         {:automation_job_run, %AutomationJobRun{id: run_id}},
         now
       ) do
    event
    |> ScheduledEvent.changeset(%{
      status: "fired",
      automation_job_run_id: run_id,
      fired_at: now,
      last_fire_error: %{}
    })
    |> repo.update()
  end

  defp fire_result(event, {:actor_event, actor_event}) do
    %{status: :fired, scheduled_event: event, actor_event: actor_event}
  end

  defp fire_result(event, {:automation_job_run, run}) do
    %{status: :fired, scheduled_event: event, automation_job_run: run}
  end

  defp mark_event_cancelled(repo, %ScheduledEvent{} = event, now, reason) do
    with {:ok, event} <-
           event
           |> ScheduledEvent.changeset(%{
             status: "cancelled",
             cancelled_at: now,
             last_fire_error: %{"reason" => inspect(reason)}
           })
           |> repo.update() do
      {:ok, %{status: :cancelled, scheduled_event: event}}
    end
  end

  defp actor_event_type(%ScheduledEvent{kind: "check_back_later"}), do: "check_back_later.wakeup"
  defp actor_event_type(%ScheduledEvent{kind: "cron_fire"}), do: "cron.fire"

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

  defp actor_event_payload(%ScheduledEvent{} = event, now) do
    %{
      "specversion" => "1.0",
      "id" => source_event_id(event),
      "source" => "control-plane://schedule/#{event.kind}",
      "subject" => "schedule:#{event.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => actor_event_type(event),
      "data" => %{
        "scheduled_event_id" => event.id,
        "schedule_kind" => event.kind,
        "due_at" => DateTime.to_iso8601(event.due_at),
        "fired_at" => DateTime.to_iso8601(now),
        "timezone" => event.timezone,
        "cron_schedule_id" => event.cron_schedule_id,
        "cron_fire_slot_at" => Planner.datetime(event.cron_fire_slot_at),
        "wake_payload" => event.wake_payload || %{},
        "reply_route" =>
          Attrs.reject_nil_values(%{
            "binding_name" => event.binding_name,
            "signal_channel_id" => event.signal_channel_id,
            "provider_thread_id" => event.provider_thread_id,
            "source_entry_id" => event.source_entry_id
          })
      }
    }
  end

  defp persist_fire_error({:error, reason} = error, scheduled_event_id, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case Repo.transact(fn repo ->
           persist_fire_error_in_tx(repo, scheduled_event_id, reason, now, opts)
         end) do
      {:ok, _event} ->
        error

      {:error, persistence_reason} ->
        {:error, {:fire_error_persistence_failed, reason, persistence_reason}}
    end
  end

  defp persist_fire_error(result, _scheduled_event_id, _opts), do: result

  defp persist_fire_error_in_tx(repo, scheduled_event_id, reason, now, opts) do
    case repo.get(ScheduledEvent, scheduled_event_id) do
      %ScheduledEvent{kind: "cron_fire", cron_schedule_id: cron_schedule_id}
      when is_binary(cron_schedule_id) ->
        schedule = Store.lock_cron_schedule(repo, cron_schedule_id)

        with {:ok, event} <-
               persist_locked_fire_error(repo, scheduled_event_id, reason, now, opts),
             {:ok, _schedule} <-
               maybe_advance_after_terminal_failure(repo, schedule, event, now, opts) do
          {:ok, event}
        end

      %ScheduledEvent{} ->
        persist_locked_fire_error(repo, scheduled_event_id, reason, now, opts)

      nil ->
        {:ok, nil}
    end
  end

  defp persist_locked_fire_error(repo, scheduled_event_id, reason, now, opts) do
    case Store.lock_scheduled_event(repo, scheduled_event_id) do
      %ScheduledEvent{status: status} when status in ["scheduled", "firing"] ->
        persisted_status = if terminal_fire_failure?(opts), do: "failed", else: "scheduled"
        attempt = fire_attempt(opts)

        ScheduledEvent
        |> where([event], event.id == ^scheduled_event_id)
        |> update([event],
          set: [
            status: ^persisted_status,
            fire_attempts: fragment("GREATEST(?, ?)", event.fire_attempts, ^attempt),
            fire_claimed_at: ^now,
            last_fire_error: ^%{"reason" => inspect(reason)},
            updated_at: ^now
          ]
        )
        |> repo.update_all([])

        {:ok, repo.get!(ScheduledEvent, scheduled_event_id)}

      %ScheduledEvent{} = event ->
        {:ok, event}

      nil ->
        {:ok, nil}
    end
  end

  defp maybe_advance_after_terminal_failure(
         repo,
         %CronSchedule{} = schedule,
         %ScheduledEvent{status: "failed"} = event,
         now,
         opts
       ) do
    Cron.advance_after_terminal_failure(repo, schedule, event, now, opts)
  end

  defp maybe_advance_after_terminal_failure(
         _repo,
         _schedule,
         _event,
         _now,
         _opts
       ),
       do: {:ok, nil}

  defp fire_attempt(opts) do
    case Keyword.get(opts, :attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt
      _value -> 1
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
