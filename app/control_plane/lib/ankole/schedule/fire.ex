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
  alias Ankole.Schedule.Jobs.FireCron

  @spec fire_due_event(pos_integer(), keyword()) ::
          {:ok, %{status: :fired | :noop | :cancelled, scheduled_event: ScheduledEvent.t() | nil}}
          | {:error, term()}
  def fire_due_event(scheduled_event_id, opts \\ [])
      when is_integer(scheduled_event_id) and scheduled_event_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, authorized} <- authorize_fire_in_tx(repo, scheduled_event_id, now),
           {:ok, event, schedule} <-
             claim_due_event_with_schedule_in_tx(repo, scheduled_event_id, now),
           true <- event.automation_job_id == authorized.automation_job_id,
           {:ok, result} <- fire_claimed_event_in_tx(repo, event, schedule, now, opts) do
        {:ok, result}
      else
        false -> {:error, :scheduled_event_changed}
        :noop -> {:ok, %{status: :noop, scheduled_event: nil}}
        {:error, _reason} = error -> error
      end
    end)
    |> persist_fire_error(scheduled_event_id, opts)
    |> Ankole.Conversations.deliver_committed(&[Map.get(&1, :actor_event)])
  end

  @spec fire_cron(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fire_cron(cron_schedule_id, opts \\ []) when is_binary(cron_schedule_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case repo.get(CronSchedule, cron_schedule_id) do
        %CronSchedule{status: "active"} = schedule ->
          fire_active_cron_in_tx(repo, schedule, now)

        _schedule ->
          {:ok, %{status: :noop, scheduled_event: nil}}
      end
    end)
    |> persist_cron_error(cron_schedule_id, now, opts)
    |> Ankole.Conversations.deliver_committed(&[Map.get(&1, :actor_event)])
  end

  defp fire_active_cron_in_tx(repo, schedule, now) do
    result =
      if DateTime.after?(schedule.next_fire_at, now) do
        with :ok <-
               Ankole.Job.schedule_in_tx(
                 repo,
                 FireCron,
                 %{"cron_schedule_id" => schedule.id},
                 schedule.next_fire_at
               ) do
          {:ok, %{status: :noop, scheduled_event: nil}}
        end
      else
        with :ok <- authorize_work_in_tx(repo, schedule),
             %CronSchedule{} = locked <- Store.lock_cron_schedule(repo, schedule.id),
             true <- same_cron_fire?(locked, schedule) do
          fire_locked_cron_in_tx(repo, locked, now)
        else
          false -> {:error, :cron_schedule_changed}
          nil -> {:error, :cron_schedule_changed}
          {:error, _reason} = error -> error
        end
      end

    case result do
      {:error, reason} -> {:error, {:cron_fire_failed, reason, schedule.next_fire_at}}
      result -> result
    end
  end

  defp same_cron_fire?(locked, schedule) do
    locked.status == "active" and
      Map.take(locked, [
        :next_fire_at,
        :authorization_kind,
        :human_uid,
        :human_access_version,
        :automation_job_id
      ]) ==
        Map.take(schedule, [
          :next_fire_at,
          :authorization_kind,
          :human_uid,
          :human_access_version,
          :automation_job_id
        ])
  end

  defp fire_locked_cron_in_tx(repo, schedule, now) do
    case Cron.validate_fire_schedule(schedule) do
      :ok ->
        with {:ok, event} <- insert_cron_history(repo, schedule, now, "fired"),
             {:ok, delivery} <- deliver_scheduled_event(repo, event, now),
             {:ok, event} <- mark_event_fired(repo, event, delivery, now),
             {:ok, _schedule} <-
               Cron.advance_after_fire(repo, schedule, event.cron_fire_slot_at, now) do
          {:ok, fire_result(event, delivery)}
        end

      {:cancel, reason} ->
        with {:ok, event} <- insert_cron_history(repo, schedule, now, "cancelled", reason) do
          {:ok, %{status: :cancelled, scheduled_event: event}}
        end
    end
  end

  defp insert_cron_history(repo, schedule, now, status, reason \\ nil) do
    key = Store.cron_fire_idempotency_key(schedule.id, schedule.next_fire_at)

    attrs_result =
      if status == "cancelled" do
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
      attrs =
        Map.merge(attrs, %{
          status: status,
          last_fire_error: if(reason, do: %{"reason" => inspect(reason)}, else: %{})
        })

      attrs =
        case status do
          "fired" -> Map.put(attrs, :fired_at, now)
          "cancelled" -> Map.put(attrs, :cancelled_at, now)
          "failed" -> attrs
        end

      %ScheduledEvent{} |> ScheduledEvent.changeset(attrs) |> repo.insert()
    end
  end

  defp persist_cron_error({:error, {:cron_fire_failed, reason, slot}}, id, now, opts) do
    result =
      if terminal_fire_failure?(opts) do
        Repo.transact(fn repo ->
          case Store.lock_cron_schedule(repo, id) do
            %CronSchedule{status: "active", next_fire_at: ^slot} = schedule ->
              with {:ok, _event} <- insert_cron_history(repo, schedule, now, "failed", reason) do
                Cron.advance_after_terminal_failure(repo, schedule, now)
              end

            _schedule ->
              {:ok, nil}
          end
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

  defp persist_cron_error(result, _id, _now, _opts), do: result

  defp authorize_fire_in_tx(repo, id, now) do
    case repo.get(ScheduledEvent, id) do
      %ScheduledEvent{status: "scheduled"} = event ->
        authorize_scheduled_event_in_tx(repo, event, now)

      _ ->
        :noop
    end
  end

  # Only a due, unclaimed event admits new work. Terminal and future events are noops.
  defp authorize_scheduled_event_in_tx(repo, event, now) do
    if DateTime.compare(event.due_at, now) == :gt do
      :noop
    else
      with :ok <- authorize_work_in_tx(repo, event), do: {:ok, event}
    end
  end

  defp authorize_work_in_tx(repo, work) do
    job =
      if work.automation_job_id,
        do: repo.get(Ankole.AutomationJobs.Schemas.Job, work.automation_job_id)

    # Lock all Human sources in uid order before a work row.
    sources = Enum.sort_by([work | if(job, do: [job], else: [])], &(&1.human_uid || ""))

    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()) do
      Enum.reduce_while(sources, :ok, fn source, :ok ->
        case Ankole.Principals.WorkAccess.check_in_tx(repo, source) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
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

    case query |> lock("FOR UPDATE") |> repo.one() do
      %ScheduledEvent{} = event -> {:ok, event}
      nil -> :noop
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
         _opts
       ) do
    with %CronSchedule{} = schedule <- schedule,
         :ok <- Cron.validate_fire_schedule(schedule),
         {:ok, delivery} <- deliver_scheduled_event(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, delivery, now) do
      {:ok, fire_result(event, delivery)}
    else
      nil -> mark_event_cancelled(repo, event, now, :cron_schedule_not_found)
      {:cancel, reason} -> mark_event_cancelled(repo, event, now, reason)
      {:error, _reason} = error -> error
    end
  end

  defp append_scheduled_actor_event(repo, %ScheduledEvent{} = event, now) do
    SignalsGateway.append_actor_event_in_tx(repo, %{
      source_work: event,
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
    with {:ok, %{automation_job_run: run} = result} <-
           AutomationJobs.enqueue_run_in_tx(
             repo,
             automation_job_id,
             event.agent_uid,
             actor_event_payload(event, now),
             now: now
           ) do
      {:ok, {:automation_job_run, run, Map.get(result, :actor_event)}}
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
         {:automation_job_run, %AutomationJobRun{id: run_id}, _actor_event},
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

  defp fire_result(event, {:automation_job_run, run, actor_event}) do
    %{status: :fired, scheduled_event: event, automation_job_run: run, actor_event: actor_event}
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
           persist_locked_fire_error(repo, scheduled_event_id, reason, now, opts)
         end) do
      {:ok, _event} ->
        error

      {:error, persistence_reason} ->
        {:error, {:fire_error_persistence_failed, reason, persistence_reason}}
    end
  end

  defp persist_fire_error(result, _scheduled_event_id, _opts), do: result

  defp persist_locked_fire_error(repo, scheduled_event_id, reason, now, opts) do
    case Store.lock_scheduled_event(repo, scheduled_event_id) do
      %ScheduledEvent{status: "scheduled"} ->
        persisted_status = if terminal_fire_failure?(opts), do: "failed", else: "scheduled"

        ScheduledEvent
        |> where([event], event.id == ^scheduled_event_id)
        |> update([event],
          set: [
            status: ^persisted_status,
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
