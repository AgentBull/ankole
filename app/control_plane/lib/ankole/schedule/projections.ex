defmodule Ankole.Schedule.Projections do
  @moduledoc false

  alias Ankole.Schedule.Delivery
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.AgentRoutine
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @model_error_reasons ~w(
    checkback_replaced
    cron_schedule_changed
    cron_schedule_deleted
    cron_schedule_not_active
    cron_schedule_not_found
    routine_deleted
    routine_paused
    source_entry_tombstoned
    user_cancelled
  )

  # The rule's UUID stays internal and model tools address a rule by `name`, so
  # the count is how many targets a reply reaches, without naming a provider
  # channel. A model asked "how many targets" otherwise has to guess, and a guess
  # reads as fact in the reply.
  @spec cron_model_projection(CronSchedule.t()) :: map()
  def cron_model_projection(schedule), do: hd(cron_model_projections([schedule]))

  def cron_model_projections(schedules) do
    schedules
    |> Enum.zip(Ankole.Signals.source_automation_job_ids(schedules))
    |> Enum.map(fn {schedule, job_id} -> cron_projection(schedule, job_id) end)
  end

  defp cron_projection(%CronSchedule{} = schedule, job_id) do
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
      "automation_job_id" => job_id
    }
  end

  defp delivery_target_count(%CronSchedule{} = schedule) do
    case Delivery.targets(schedule.delivery || %{}, schedule.binding_name) do
      {:ok, targets} -> length(targets)
      {:error, _reason} -> 0
    end
  end

  @spec routine_model_projection(AgentRoutine.t()) :: map()
  def routine_model_projection(%AgentRoutine{} = routine),
    do: hd(routine_model_projections([routine]))

  @spec routine_model_projections([AgentRoutine.t()]) :: [map()]
  def routine_model_projections([]), do: []

  def routine_model_projections(routines) when is_list(routines) do
    routine_ids = Enum.map(routines, & &1.id)
    schedules_by_routine = Ankole.Schedule.schedules_by_owner_routines(routine_ids)
    bindings_by_routine = Ankole.Schedule.bindings_by_owner_routines(routine_ids)

    Enum.map(routines, fn routine ->
      primary_cron = List.first(Map.get(schedules_by_routine, routine.id, []))

      enabled_bindings =
        routine.id
        |> then(&Map.get(bindings_by_routine, &1, []))
        |> Enum.count(& &1.enabled)

      routine_projection(routine, primary_cron, enabled_bindings)
    end)
  end

  defp routine_projection(%AgentRoutine{} = routine, primary_cron, enabled_binding_count) do
    payload =
      case primary_cron do
        %CronSchedule{payload: cron_payload} when is_map(cron_payload) ->
          Map.put(cron_payload, "task", routine.task)

        _ ->
          %{"task" => routine.task}
      end

    %{
      "name" => routine.name,
      "status" => Atom.to_string(routine.status),
      "schedule" => if(primary_cron, do: primary_cron.schedule || %{}, else: %{}),
      "timezone" => if(primary_cron, do: primary_cron.timezone),
      "payload" => payload,
      "quiet_success" => get_in(routine.delivery || %{}, ["quiet_success"]) == true,
      "delivery_target_count" => routine_delivery_target_count(routine),
      "event_binding_count" => enabled_binding_count,
      "next_fire_at" => if(primary_cron, do: Planner.datetime(primary_cron.next_fire_at)),
      "last_fire_at" => if(primary_cron, do: Planner.datetime(primary_cron.last_fire_at)),
      "automation_job_id" => nil
    }
  end

  defp routine_delivery_target_count(%AgentRoutine{} = routine) do
    case Delivery.targets(routine.delivery || %{}, routine.binding_name) do
      {:ok, targets} -> length(targets)
      {:error, _reason} -> 0
    end
  end

  @spec routine_run_model_projections(AgentRoutine.t(), pos_integer()) :: [map()]
  def routine_run_model_projections(%AgentRoutine{} = routine, limit \\ 25)
      when is_integer(limit) and limit > 0 do
    entries = Ankole.Schedule.list_routine_run_entries(routine, limit)
    events = for {:event, event} <- entries, do: event

    event_projections_by_id =
      events
      |> event_model_projections()
      |> Enum.zip(events)
      |> Map.new(fn {projection, event} ->
        {event.id,
         projection
         |> Map.put("turn_outcome", nil)
         |> Map.put("turn_summary", nil)}
      end)

    Enum.map(entries, fn
      {:signal, signal} -> signal_run_projection(signal)
      {:event, event} -> Map.fetch!(event_projections_by_id, event.id)
    end)
  end

  defp signal_run_projection(signal) do
    data = if is_map(signal.data), do: signal.data, else: %{}

    %{
      "status" => signal_run_status(signal),
      "due_at" =>
        data["due_at"] ||
          Planner.datetime(signal.occurred_at || signal.inserted_at),
      "timezone" => data["timezone"],
      "trigger" => signal_run_trigger(signal, data),
      "signal_type" => signal.type,
      "automation_job_id" => nil,
      "automation_job_run_id" => nil,
      "deliveries" => [%{automation_job_run_id: nil, delivered_signal_id: signal.id}],
      "fired_at" => data["fired_at"] || Planner.datetime(signal.inserted_at),
      "completed_at" => Planner.datetime(signal.completed_at),
      "cancelled_at" =>
        if(signal.status == :dead_letter, do: Planner.datetime(signal.dead_letter_at)),
      "last_error" =>
        if(signal.status == :dead_letter,
          do: model_last_error(signal.dead_letter_reason),
          else: %{}
        ),
      "turn_outcome" => signal.turn_outcome,
      "turn_summary" => signal.turn_summary
    }
  end

  defp signal_run_status(%{status: :dead_letter, dead_letter_reason: %{"reason" => reason}})
       when reason in ["routine_paused", "routine_deleted"],
       do: "cancelled"

  defp signal_run_status(%{status: status}), do: Atom.to_string(status)

  defp signal_run_trigger(signal, data) do
    case signal.type do
      "cron.fire" -> data["trigger"] || "scheduled"
      "routine.manual_run" -> "manual"
      "check_back_later.wakeup" -> "check_back_later"
      _ -> "event"
    end
  end

  @spec event_model_projection(ScheduledEvent.t()) :: map()
  def event_model_projection(event), do: hd(event_model_projections([event]))

  def event_model_projections(events) do
    receipts = Ankole.Signals.delivery_receipts_by_signal(Enum.map(events, & &1.signal_id))

    events
    |> Enum.zip(Ankole.Signals.source_automation_job_ids(events))
    |> Enum.map(fn {event, job_id} ->
      event_projection(event, job_id, Map.get(receipts, event.signal_id, []))
    end)
  end

  @spec cron_run_model_projections([ScheduledEvent.t()]) :: [map()]
  def cron_run_model_projections(events) do
    projections = event_model_projections(events)

    signal_ids =
      projections
      |> Enum.flat_map(fn p -> Enum.map(p["deliveries"] || [], & &1[:delivered_signal_id]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    signals_by_id =
      case signal_ids do
        [] ->
          %{}

        ids ->
          [query: [filter: [id: [in: ids]], select: [:id, :turn_outcome, :turn_summary]]]
          |> Ankole.Signals.list_signals!()
          |> Map.new(&{&1.id, &1})
      end

    Enum.map(projections, fn projection ->
      delivered =
        Enum.find_value(projection["deliveries"] || [], fn d ->
          Map.get(signals_by_id, d[:delivered_signal_id])
        end)

      projection
      |> Map.put("turn_outcome", if(delivered, do: delivered.turn_outcome))
      |> Map.put("turn_summary", if(delivered, do: delivered.turn_summary))
    end)
  end

  defp event_projection(%ScheduledEvent{kind: "check_back_later"} = event, job_id, receipts) do
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
      "automation_job_id" => job_id,
      "automation_job_run_id" => Enum.find_value(receipts, & &1.automation_job_run_id),
      "deliveries" =>
        Enum.map(
          receipts,
          &Map.take(&1, [:automation_job_run_id, :delivered_signal_id])
        ),
      "fired_at" => Planner.datetime(event.fired_at),
      "cancelled_at" => Planner.datetime(event.cancelled_at),
      "last_error" => model_last_error(event.last_fire_error)
    }
  end

  defp event_projection(%ScheduledEvent{kind: "cron_fire"} = event, job_id, receipts) do
    wake_payload = event.wake_payload || %{}

    %{
      "status" => Atom.to_string(event.status),
      "due_at" => Planner.datetime(event.due_at),
      "timezone" => event.timezone,
      "trigger" => wake_payload["trigger"],
      "automation_job_id" => job_id,
      "automation_job_run_id" => Enum.find_value(receipts, & &1.automation_job_run_id),
      "deliveries" =>
        Enum.map(
          receipts,
          &Map.take(&1, [:automation_job_run_id, :delivered_signal_id])
        ),
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
