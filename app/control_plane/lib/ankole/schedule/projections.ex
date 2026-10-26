defmodule Ankole.Schedule.Projections do
  @moduledoc false

  alias Ankole.Schedule.Delivery
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

  # The rule's UUID stays internal and model tools address a rule by `name`, so
  # the count is how many targets a reply reaches, without naming a provider
  # channel. A model asked "how many targets" otherwise has to guess, and a guess
  # reads as fact in the reply.
  @spec cron_model_projection(CronSchedule.t()) :: map()
  def cron_model_projection(%CronSchedule{} = schedule) do
    %{
      "name" => schedule.name,
      "status" => Atom.to_string(schedule.status),
      "schedule" => schedule.schedule || %{},
      "timezone" => schedule.timezone,
      "payload" => schedule.payload || %{},
      "quiet_success" => get_in(schedule.delivery || %{}, ["quiet_success"]) == true,
      "delivery_target_count" => delivery_target_count(schedule),
      "next_fire_at" => Planner.datetime(schedule.next_fire_at),
      "last_fire_at" => Planner.datetime(schedule.last_fire_at),
      "automation_job_id" => schedule.automation_job_id
    }
  end

  defp delivery_target_count(%CronSchedule{} = schedule) do
    case Delivery.targets(schedule.delivery || %{}, schedule.binding_name) do
      {:ok, targets} -> length(targets)
      {:error, _reason} -> 0
    end
  end

  @spec event_model_projection(ScheduledEvent.t()) :: map()
  def event_model_projection(%ScheduledEvent{kind: "check_back_later"} = event) do
    wake_payload = event.wake_payload || %{}

    %{
      "checkback_id" => event.id,
      "status" => Atom.to_string(event.status),
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
      "status" => Atom.to_string(event.status),
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
    case Ankole.Attrs.get_string_first(error, "reason") do
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
