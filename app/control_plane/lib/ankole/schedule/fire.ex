defmodule Ankole.Schedule.Fire do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway
  alias Ankole.Repo
  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Cron
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Schedule.Store

  @spec fire_due_event(Ecto.UUID.t(), keyword()) ::
          {:ok, %{status: :fired | :noop | :cancelled, scheduled_event: ScheduledEvent.t() | nil}}
          | {:error, term()}
  def fire_due_event(scheduled_event_id, opts \\ []) when is_binary(scheduled_event_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, event} <- claim_due_event_in_tx(repo, scheduled_event_id, now),
           {:ok, result} <- fire_claimed_event_in_tx(repo, event, now, opts) do
        {:ok, result}
      else
        :noop -> {:ok, %{status: :noop, scheduled_event: nil}}
        {:error, _reason} = error -> error
      end
    end)
    |> persist_fire_error(scheduled_event_id, opts)
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
         now,
         _opts
       ) do
    with {:ok, actor_event} <- append_scheduled_actor_event(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, actor_event, now) do
      {:ok, %{status: :fired, scheduled_event: event, actor_event: actor_event}}
    end
  end

  defp fire_claimed_event_in_tx(repo, %ScheduledEvent{kind: "cron_fire"} = event, now, opts) do
    with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, event.cron_schedule_id),
         :ok <- Cron.validate_fire_schedule_active(schedule, event),
         {:ok, actor_event} <- append_scheduled_actor_event(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, actor_event, now),
         {:ok, _schedule} <- Cron.advance_after_fire(repo, schedule, event, now, opts) do
      {:ok, %{status: :fired, scheduled_event: event, actor_event: actor_event}}
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

  defp mark_event_fired(repo, %ScheduledEvent{} = event, %{id: actor_event_id}, now) do
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

  defp source_event_id(%ScheduledEvent{
         kind: "cron_fire",
         cron_schedule_id: cron_schedule_id,
         cron_fire_slot_at: %DateTime{} = slot_at
       }),
       do: Store.cron_idempotency_key(cron_schedule_id, slot_at)

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
    now = DateTime.utc_now(:microsecond)
    attempt = fire_attempt(opts)
    status = if terminal_fire_failure?(opts), do: "failed", else: "scheduled"

    ScheduledEvent
    |> where([event], event.id == ^scheduled_event_id)
    |> where([event], event.status in ["scheduled", "firing"])
    |> update([event],
      set: [
        status: ^status,
        fire_attempts: fragment("GREATEST(?, ?)", event.fire_attempts, ^attempt),
        fire_claimed_at: ^now,
        last_fire_error: ^%{"reason" => inspect(reason)},
        updated_at: ^now
      ]
    )
    |> Repo.update_all([])

    error
  end

  defp persist_fire_error(result, _scheduled_event_id, _opts), do: result

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
