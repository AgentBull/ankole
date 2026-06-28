defmodule Ankole.Schedule.Normalizer do
  @moduledoc false

  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule

  @max_reason_length 2_000
  @max_check_length 4_000
  @max_context_summary_length 8_000

  @spec checkback_attrs(map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def checkback_attrs(attrs, now, opts) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with {:ok, timezone} <-
           Planner.schedule_timezone(Attrs.map_value(attrs, "schedule"), attrs, opts),
         {:ok, due_at} <-
           Planner.parse_checkback_due(Attrs.map_value(attrs, "schedule"), timezone, now, opts),
         :ok <- Planner.validate_bounds(due_at, now, opts),
         {:ok, reason} <- Attrs.bounded_text(attrs, "reason", @max_reason_length),
         {:ok, check} <- Attrs.bounded_text(attrs, "check", @max_check_length),
         {:ok, context_summary} <-
           Attrs.optional_bounded_text(attrs, "context_summary", @max_context_summary_length),
         {:ok, tool_call_id} <- Attrs.required_text(attrs, "tool_call_id"),
         {:ok, idempotency_key} <- Attrs.required_text(attrs, "idempotency_key"),
         {:ok, agent_uid} <- Attrs.required_text(attrs, "agent_uid"),
         {:ok, session_id} <- Attrs.required_text(attrs, "session_id"),
         {:ok, binding_name} <- Attrs.required_text(attrs, "binding_name") do
      reply_route = Attrs.map_value(attrs, "reply_route") || %{}

      {:ok,
       %{
         kind: "check_back_later",
         status: "scheduled",
         agent_uid: agent_uid,
         session_id: session_id,
         binding_name: binding_name,
         due_at: due_at,
         timezone: timezone,
         requested_at: now,
         idempotency_key: idempotency_key,
         tool_call_id: tool_call_id,
         source_llm_turn_id: Attrs.map_text(attrs, "source_llm_turn_id"),
         source_actor_input_id: Attrs.map_text(attrs, "source_actor_input_id"),
         signal_channel_id: Attrs.map_text(reply_route, "signal_channel_id"),
         provider_thread_id: Attrs.map_text(reply_route, "provider_thread_id"),
         provider_entry_id: Attrs.map_text(reply_route, "provider_entry_id"),
         source_provenance: Attrs.map_value(attrs, "source_provenance") || %{},
         wake_payload: %{
           "reason" => reason,
           "check" => check,
           "context_summary" => context_summary,
           "due_at" => DateTime.to_iso8601(due_at),
           "timezone" => timezone,
           "schedule" => Attrs.map_value(attrs, "schedule") || %{}
         },
         last_fire_error: %{}
       }}
    end
  end

  @spec cron_schedule_attrs(map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cron_schedule_attrs(attrs, now, opts) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with {:ok, agent_uid} <- Attrs.required_text(attrs, "agent_uid"),
         {:ok, session_id} <- Attrs.required_text(attrs, "session_id"),
         {:ok, binding_name} <- Attrs.required_text(attrs, "binding_name"),
         {:ok, idempotency_key} <- Attrs.required_text(attrs, "idempotency_key"),
         {:ok, schedule, timezone} <-
           Planner.normalize_schedule_json(Attrs.map_value(attrs, "schedule"), attrs, opts),
         {:ok, delivery} <- normalize_cron_delivery(Attrs.map_value(attrs, "delivery")),
         {:ok, status} <- normalize_cron_status(Attrs.map_text(attrs, "status") || "active"),
         {:ok, next_fire_at} <- Planner.next_fire_after(schedule, timezone, now) do
      {:ok,
       %{
         status: status,
         agent_uid: agent_uid,
         session_id: session_id,
         binding_name: binding_name,
         name: Attrs.map_text(attrs, "name"),
         schedule: schedule,
         timezone: timezone,
         payload: Attrs.map_value(attrs, "payload") || %{},
         delivery: delivery,
         next_fire_at: next_fire_at_for_status(status, next_fire_at),
         idempotency_key: idempotency_key,
         created_by: Attrs.map_value(attrs, "created_by") || %{"kind" => "operator_api"},
         failure_policy: Attrs.map_value(attrs, "failure_policy") || %{}
       }}
    end
  end

  @spec cron_schedule_update_attrs(CronSchedule.t(), map(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cron_schedule_update_attrs(%CronSchedule{} = existing, attrs, now, opts) do
    attrs = Attrs.normalize_external_attrs(attrs)
    schedule_input = Map.get(attrs, "schedule", existing.schedule)
    base = %{"timezone" => Map.get(attrs, "timezone", existing.timezone)}
    delivery_input = Map.get(attrs, "delivery", existing.delivery)
    status_input = Map.get(attrs, "status", existing.status)

    with {:ok, schedule, timezone} <- Planner.normalize_schedule_json(schedule_input, base, opts),
         {:ok, delivery} <- normalize_cron_delivery(delivery_input),
         {:ok, status} <- normalize_cron_status(status_input),
         {:ok, next_fire_at} <- Planner.next_fire_after(schedule, timezone, now) do
      {:ok,
       %{}
       |> Attrs.maybe_put(:status, Map.get(attrs, "status"))
       |> Attrs.maybe_put(:name, Map.get(attrs, "name"))
       |> Attrs.maybe_put(:schedule, schedule)
       |> Attrs.maybe_put(:timezone, timezone)
       |> Attrs.maybe_put(:payload, Map.get(attrs, "payload"))
       |> Attrs.maybe_put(:delivery, delivery)
       |> Attrs.maybe_put(:failure_policy, Map.get(attrs, "failure_policy"))
       |> Map.put(:next_fire_at, next_fire_at_for_status(status, next_fire_at))}
    end
  end

  defp next_fire_at_for_status("active", %DateTime{} = next_fire_at), do: next_fire_at
  defp next_fire_at_for_status(_status, _next_fire_at), do: nil

  defp normalize_cron_status(status) when status in ["active", "paused"], do: {:ok, status}
  defp normalize_cron_status(status) when status in ["deleted", "failed"], do: {:ok, status}
  defp normalize_cron_status(_status), do: {:error, :invalid_cron_status}

  defp normalize_cron_delivery(delivery) when is_map(delivery) do
    case Attrs.required_text(delivery, "signal_channel_id") do
      {:ok, _signal_channel_id} -> {:ok, delivery}
      {:error, _reason} -> {:error, :cron_delivery_route_required}
    end
  end

  defp normalize_cron_delivery(_delivery), do: {:error, :cron_delivery_route_required}
end
