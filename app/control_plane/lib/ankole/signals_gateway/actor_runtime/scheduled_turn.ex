defmodule Ankole.SignalsGateway.ActorRuntime.ScheduledTurn do
  @moduledoc false

  import Ankole.SignalsGateway.ActorRuntime.Common

  alias Ankole.SignalsGateway.ActorEvent

  def opts(%ActorEvent{type: type} = input, opts) do
    base_context = Keyword.get(opts, :request_context, %{})
    schedule_context = scheduled_turn_context(input)

    Keyword.merge(opts,
      kind: scheduled_turn_kind(type),
      request_context: Map.merge(base_context, schedule_context)
    )
  end

  defp scheduled_turn_kind("check_back_later.wakeup"), do: "checkback_generation"
  defp scheduled_turn_kind("cron.fire"), do: "scheduled_task"

  defp scheduled_turn_context(%ActorEvent{type: type} = input) do
    data = actor_event_data(input)
    wake_payload = map_value(data, "wake_payload") || %{}
    delivery = map_value(wake_payload, "delivery") || %{}

    %{
      "turn_mode" => scheduled_turn_mode(type),
      "schedule_origin" =>
        reject_nil_values(%{
          "actor_event_type" => type,
          "actor_event_id" => input.id,
          "scheduled_event_id" => map_text(data, "scheduled_event_id"),
          "schedule_kind" => map_text(data, "schedule_kind"),
          "due_at" => map_text(data, "due_at"),
          "fired_at" => map_text(data, "fired_at"),
          "timezone" => map_text(data, "timezone"),
          "cron_schedule_id" => map_text(data, "cron_schedule_id"),
          "cron_schedule_name" => map_text(wake_payload, "cron_schedule_name"),
          "cron_fire_slot_at" => map_text(data, "cron_fire_slot_at"),
          "trigger" => map_text(wake_payload, "trigger"),
          "reply_route" => map_value(data, "reply_route") || %{},
          "payload" => map_value(wake_payload, "payload") || %{},
          "delivery" => delivery
        }),
      "silent_success_allowed" => silent_success_allowed?(input)
    }
  end

  defp scheduled_turn_mode("check_back_later.wakeup"), do: "check_back_later"
  defp scheduled_turn_mode("cron.fire"), do: "cron"

  @spec silent_success_allowed?(ActorEvent.t()) :: boolean()
  def silent_success_allowed?(%ActorEvent{type: "check_back_later.wakeup"} = event) do
    wake_payload = event |> actor_event_data() |> map_value("wake_payload")
    map_value(wake_payload, "quiet_success") == true
  end

  def silent_success_allowed?(%ActorEvent{type: "cron.fire"} = event) do
    wake_payload = event |> actor_event_data() |> map_value("wake_payload")
    delivery = map_value(wake_payload, "delivery")
    map_value(delivery, "quiet_success") == true
  end

  def silent_success_allowed?(%ActorEvent{}), do: false

  defp actor_event_data(%ActorEvent{payload: payload}) when is_map(payload) do
    map_value(payload, "data") || %{}
  end

  defp actor_event_data(_event), do: %{}
end
