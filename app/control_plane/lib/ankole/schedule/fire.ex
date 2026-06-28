defmodule Ankole.Schedule.Fire do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Actors
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
    |> persist_fire_error(scheduled_event_id)
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
    with {:ok, actor_input} <- append_scheduled_actor_input(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, actor_input, now) do
      {:ok, %{status: :fired, scheduled_event: event, actor_input: actor_input}}
    end
  end

  defp fire_claimed_event_in_tx(repo, %ScheduledEvent{kind: "cron_fire"} = event, now, opts) do
    with %CronSchedule{} = schedule <- Store.lock_cron_schedule(repo, event.cron_schedule_id),
         :ok <- Cron.validate_fire_schedule_active(schedule, event),
         {:ok, actor_input} <- append_scheduled_actor_input(repo, event, now),
         {:ok, event} <- mark_event_fired(repo, event, actor_input, now),
         {:ok, _schedule} <- Cron.advance_after_fire(repo, schedule, event, now, opts) do
      {:ok, %{status: :fired, scheduled_event: event, actor_input: actor_input}}
    else
      nil -> mark_event_cancelled(repo, event, now, :cron_schedule_not_found)
      {:cancel, reason} -> mark_event_cancelled(repo, event, now, reason)
      {:error, _reason} = error -> error
    end
  end

  defp append_scheduled_actor_input(repo, %ScheduledEvent{} = event, now) do
    Actors.append_actor_input_in_tx(repo, %{
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      session_id: event.session_id,
      ingress_event_id: ingress_event_id(event),
      signal_channel_id: event.signal_channel_id,
      provider_thread_id: event.provider_thread_id,
      provider_entry_id: event.provider_entry_id,
      type: actor_input_type(event),
      available_at: now,
      sender_key: nil,
      payload: actor_input_payload(event, now)
    })
  end

  defp mark_event_fired(repo, %ScheduledEvent{} = event, %{id: actor_input_id}, now) do
    event
    |> ScheduledEvent.changeset(%{
      status: "fired",
      actor_input_id: actor_input_id,
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

  defp actor_input_type(%ScheduledEvent{kind: "check_back_later"}), do: "check_back_later.wakeup"
  defp actor_input_type(%ScheduledEvent{kind: "cron_fire"}), do: "cron.fire"

  defp ingress_event_id(%ScheduledEvent{kind: "check_back_later", id: id}),
    do: "check_back_later:#{id}:wakeup"

  defp ingress_event_id(%ScheduledEvent{
         kind: "cron_fire",
         cron_schedule_id: cron_schedule_id,
         cron_fire_slot_at: %DateTime{} = slot_at
       }),
       do: Store.cron_idempotency_key(cron_schedule_id, slot_at)

  defp actor_input_payload(%ScheduledEvent{} = event, now) do
    %{
      "specversion" => "1.0",
      "id" => ingress_event_id(event),
      "source" => "control-plane://schedule/#{event.kind}",
      "subject" => "schedule:#{event.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => actor_input_type(event),
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
            "provider_entry_id" => event.provider_entry_id
          })
      }
    }
  end

  defp persist_fire_error({:error, reason} = error, scheduled_event_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(event in ScheduledEvent,
        where: event.id == ^scheduled_event_id and event.status == "firing"
      ),
      set: [
        status: "scheduled",
        last_fire_error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )

    error
  end

  defp persist_fire_error(result, _scheduled_event_id), do: result
end
