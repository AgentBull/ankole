defmodule Ankole.Schedule.Projections do
  @moduledoc false

  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @spec cron_projection(CronSchedule.t()) :: map()
  def cron_projection(%CronSchedule{} = schedule) do
    %{
      "id" => schedule.id,
      "status" => schedule.status,
      "agent_uid" => schedule.agent_uid,
      "session_id" => schedule.session_id,
      "binding_name" => schedule.binding_name,
      "name" => schedule.name,
      "schedule" => schedule.schedule || %{},
      "timezone" => schedule.timezone,
      "payload" => schedule.payload || %{},
      "delivery" => schedule.delivery,
      "next_fire_at" => Planner.datetime(schedule.next_fire_at),
      "last_fire_at" => Planner.datetime(schedule.last_fire_at),
      "idempotency_key" => schedule.idempotency_key,
      "created_by" => schedule.created_by || %{},
      "failure_policy" => schedule.failure_policy || %{},
      "inserted_at" => Planner.datetime(schedule.inserted_at),
      "updated_at" => Planner.datetime(schedule.updated_at)
    }
  end

  @spec event_projection(ScheduledEvent.t()) :: map()
  def event_projection(%ScheduledEvent{} = event) do
    %{
      "id" => event.id,
      "kind" => event.kind,
      "status" => event.status,
      "agent_uid" => event.agent_uid,
      "session_id" => event.session_id,
      "binding_name" => event.binding_name,
      "due_at" => Planner.datetime(event.due_at),
      "timezone" => event.timezone,
      "requested_at" => Planner.datetime(event.requested_at),
      "idempotency_key" => event.idempotency_key,
      "cron_schedule_id" => event.cron_schedule_id,
      "cron_fire_slot_at" => Planner.datetime(event.cron_fire_slot_at),
      "tool_call_id" => event.tool_call_id,
      "source_llm_turn_id" => event.source_llm_turn_id,
      "source_actor_input_id" => event.source_actor_input_id,
      "signal_channel_id" => event.signal_channel_id,
      "provider_thread_id" => event.provider_thread_id,
      "provider_entry_id" => event.provider_entry_id,
      "source_provenance" => event.source_provenance || %{},
      "wake_payload" => event.wake_payload || %{},
      "oban_job_id" => event.oban_job_id,
      "actor_input_id" => event.actor_input_id,
      "fire_attempts" => event.fire_attempts,
      "fire_claimed_at" => Planner.datetime(event.fire_claimed_at),
      "fired_at" => Planner.datetime(event.fired_at),
      "cancelled_at" => Planner.datetime(event.cancelled_at),
      "last_fire_error" => event.last_fire_error || %{},
      "inserted_at" => Planner.datetime(event.inserted_at),
      "updated_at" => Planner.datetime(event.updated_at)
    }
  end
end
