defmodule Ankole.Schedule.Projections do
  @moduledoc false

  alias Ankole.Schedule.Cron
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @model_error_reasons ~w(
    checkback_replaced
    cron_schedule_changed
    cron_schedule_deleted
    cron_schedule_not_active
    cron_schedule_not_found
    source_entry_tombstoned
    user_cancelled
  )

  @spec cron_projection(CronSchedule.t()) :: map()
  def cron_projection(%CronSchedule{} = schedule) do
    %{
      "id" => schedule.id,
      "status" => schedule.status,
      "agent_uid" => schedule.agent_uid,
      "owner_session_id" => schedule.owner_session_id,
      "execution_session_id" => Cron.execution_session_id(schedule.id),
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
      "automation_job_id" => schedule.automation_job_id,
      "inserted_at" => Planner.datetime(schedule.inserted_at),
      "updated_at" => Planner.datetime(schedule.updated_at)
    }
  end

  @spec cron_model_projection(CronSchedule.t()) :: map()
  def cron_model_projection(%CronSchedule{} = schedule) do
    %{
      "name" => schedule.name,
      "status" => schedule.status,
      "schedule" => schedule.schedule || %{},
      "timezone" => schedule.timezone,
      "payload" => schedule.payload || %{},
      "quiet_success" => get_in(schedule.delivery || %{}, ["quiet_success"]) == true,
      "next_fire_at" => Planner.datetime(schedule.next_fire_at),
      "last_fire_at" => Planner.datetime(schedule.last_fire_at),
      "automation_job_id" => schedule.automation_job_id
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
      "automation_job_id" => event.automation_job_id,
      "automation_job_run_id" => event.automation_job_run_id,
      "cron_fire_slot_at" => Planner.datetime(event.cron_fire_slot_at),
      "tool_call_id" => event.tool_call_id,
      "origin_ai_message_id" => event.origin_ai_message_id,
      "source_actor_event_id" => event.source_actor_event_id,
      "signal_channel_id" => event.signal_channel_id,
      "provider_thread_id" => event.provider_thread_id,
      "source_entry_id" => event.source_entry_id,
      "source_provenance" => event.source_provenance || %{},
      "wake_payload" => event.wake_payload || %{},
      "oban_job_id" => event.oban_job_id,
      "actor_event_id" => event.actor_event_id,
      "fire_attempts" => event.fire_attempts,
      "fire_claimed_at" => Planner.datetime(event.fire_claimed_at),
      "fired_at" => Planner.datetime(event.fired_at),
      "cancelled_at" => Planner.datetime(event.cancelled_at),
      "last_fire_error" => event.last_fire_error || %{},
      "inserted_at" => Planner.datetime(event.inserted_at),
      "updated_at" => Planner.datetime(event.updated_at)
    }
  end

  @spec event_model_projection(ScheduledEvent.t()) :: map()
  def event_model_projection(%ScheduledEvent{kind: "check_back_later"} = event) do
    wake_payload = event.wake_payload || %{}

    %{
      "checkback_id" => event.id,
      "status" => event.status,
      "due_at" => Planner.datetime(event.due_at),
      "timezone" => event.timezone,
      "reason" => wake_payload["reason"],
      "check" => wake_payload["check"],
      "context_summary" => wake_payload["context_summary"],
      "quiet_success" => wake_payload["quiet_success"] == true,
      "automation_job_id" => event.automation_job_id,
      "automation_job_run_id" => event.automation_job_run_id,
      "fired_at" => Planner.datetime(event.fired_at),
      "cancelled_at" => Planner.datetime(event.cancelled_at),
      "last_error" => model_last_error(event.last_fire_error)
    }
  end

  def event_model_projection(%ScheduledEvent{kind: "cron_fire"} = event) do
    wake_payload = event.wake_payload || %{}

    %{
      "status" => event.status,
      "due_at" => Planner.datetime(event.due_at),
      "timezone" => event.timezone,
      "trigger" => wake_payload["trigger"],
      "automation_job_id" => event.automation_job_id,
      "automation_job_run_id" => event.automation_job_run_id,
      "fired_at" => Planner.datetime(event.fired_at),
      "cancelled_at" => Planner.datetime(event.cancelled_at),
      "last_error" => model_last_error(event.last_fire_error)
    }
  end

  defp model_last_error(error) when is_map(error) do
    case Map.get(error, "reason", Map.get(error, :reason)) do
      reason when is_binary(reason) and reason != "" ->
        reason = String.trim_leading(reason, ":")

        %{
          "reason" =>
            if(reason in @model_error_reasons,
              do: reason,
              else: "schedule_fire_failed"
            )
        }

      _reason ->
        %{}
    end
  end

  defp model_last_error(_error), do: %{}
end
