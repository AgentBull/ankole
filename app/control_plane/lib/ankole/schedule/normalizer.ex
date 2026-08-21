defmodule Ankole.Schedule.Normalizer do
  @moduledoc false

  alias Ankole.Schedule.Attrs
  alias Ankole.Schedule.Delivery
  alias Ankole.Schedule.Planner
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @max_reason_length 2_000
  @max_check_length 4_000
  @max_context_summary_length 8_000

  @spec checkback_attrs(map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def checkback_attrs(attrs, now, opts) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with {:ok, due_at, timezone, schedule} <- normalize_checkback_schedule(attrs, now, opts) do
      build_checkback_attrs(attrs, due_at, timezone, schedule, now)
    end
  end

  @spec checkback_replacement_attrs(ScheduledEvent.t(), map(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def checkback_replacement_attrs(%ScheduledEvent{} = existing, attrs, now, opts) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    source_provenance =
      case Attrs.map_value(attrs, "source_provenance") do
        value when is_map(value) -> Map.put(value, "replaces_scheduled_event_id", existing.id)
        _value -> %{"replaces_scheduled_event_id" => existing.id}
      end

    merged_attrs =
      existing
      |> existing_checkback_values()
      |> Map.merge(attrs)
      |> Map.put("source_provenance", source_provenance)

    with {:ok, due_at, timezone, schedule} <-
           replacement_checkback_schedule(existing, attrs, now, opts) do
      build_checkback_attrs(merged_attrs, due_at, timezone, schedule, now)
    end
  end

  defp build_checkback_attrs(attrs, due_at, timezone, schedule, now) do
    with {:ok, reason} <- Attrs.bounded_text(attrs, "reason", @max_reason_length),
         {:ok, check} <- Attrs.bounded_text(attrs, "check", @max_check_length),
         {:ok, context_summary} <-
           Attrs.optional_bounded_text(attrs, "context_summary", @max_context_summary_length),
         {:ok, quiet_success} <- optional_boolean(attrs, "quiet_success", false),
         {:ok, tool_call_id} <- Attrs.required_text(attrs, "tool_call_id"),
         {:ok, idempotency_key} <- Attrs.required_text(attrs, "idempotency_key"),
         {:ok, agent_uid} <- Attrs.required_text(attrs, "agent_uid"),
         {:ok, session_id} <- Attrs.required_text(attrs, "session_id"),
         {:ok, binding_name} <- Attrs.required_text(attrs, "binding_name"),
         {:ok, automation_job_id} <- optional_positive_integer(attrs, "automation_job_id") do
      reply_route = Attrs.map_value(attrs, "reply_route") || %{}

      {:ok,
       %{
         kind: "check_back_later",
         status: "scheduled",
         agent_uid: agent_uid,
         session_id: session_id,
         binding_name: binding_name,
         automation_job_id: automation_job_id,
         due_at: due_at,
         timezone: timezone,
         requested_at: now,
         idempotency_key: idempotency_key,
         tool_call_id: tool_call_id,
         # Source tables: origin_ai_message_id is ai_gateway_messages.id;
         # source_actor_event_id is actor_events.id from the turn that scheduled it.
         origin_ai_message_id: Attrs.map_text(attrs, "origin_ai_message_id"),
         source_actor_event_id: Attrs.map_text(attrs, "source_actor_event_id"),
         signal_channel_id: Attrs.map_text(reply_route, "signal_channel_id"),
         provider_thread_id: Attrs.map_text(reply_route, "provider_thread_id"),
         source_entry_id: Attrs.map_text(reply_route, "source_entry_id"),
         source_provenance: Attrs.map_value(attrs, "source_provenance") || %{},
         wake_payload: %{
           "reason" => reason,
           "check" => check,
           "context_summary" => context_summary,
           "quiet_success" => quiet_success,
           "due_at" => DateTime.to_iso8601(due_at),
           "timezone" => timezone,
           "schedule" => schedule
         },
         last_fire_error: %{}
       }}
    end
  end

  defp normalize_checkback_schedule(attrs, now, opts) do
    schedule = Attrs.map_value(attrs, "schedule")

    with {:ok, timezone} <- Planner.schedule_timezone(schedule, attrs, opts),
         {:ok, due_at} <- Planner.parse_checkback_due(schedule, timezone, now, opts),
         :ok <- Planner.validate_bounds(due_at, now, opts) do
      {:ok, due_at, timezone, schedule}
    end
  end

  defp replacement_checkback_schedule(existing, attrs, now, opts) do
    case Map.has_key?(attrs, "schedule") do
      true ->
        normalize_checkback_schedule(attrs, now, opts)

      false ->
        schedule =
          get_in(existing.wake_payload || %{}, ["schedule"]) ||
            %{"at" => DateTime.to_iso8601(existing.due_at), "timezone" => existing.timezone}

        {:ok, existing.due_at, existing.timezone, schedule}
    end
  end

  defp existing_checkback_values(%ScheduledEvent{} = event) do
    wake_payload = event.wake_payload || %{}

    %{
      "reason" => Map.get(wake_payload, "reason"),
      "check" => Map.get(wake_payload, "check"),
      "context_summary" => Map.get(wake_payload, "context_summary"),
      "quiet_success" => Map.get(wake_payload, "quiet_success") == true,
      "automation_job_id" => event.automation_job_id
    }
  end

  @spec cron_schedule_attrs(map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cron_schedule_attrs(attrs, now, opts) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with {:ok, agent_uid} <- Attrs.required_text(attrs, "agent_uid"),
         {:ok, owner_session_id} <- Attrs.required_text(attrs, "owner_session_id"),
         :ok <- reject_reserved_owner_session(owner_session_id),
         {:ok, binding_name} <- Attrs.required_text(attrs, "binding_name"),
         {:ok, name} <- Attrs.required_text(attrs, "name"),
         {:ok, idempotency_key} <- Attrs.required_text(attrs, "idempotency_key"),
         {:ok, schedule, timezone} <-
           Planner.normalize_schedule_json(Attrs.map_value(attrs, "schedule"), attrs, opts),
         {:ok, delivery} <-
           Delivery.normalize(Attrs.map_value(attrs, "delivery"), binding_name),
         {:ok, status} <- normalize_cron_status(Attrs.map_text(attrs, "status") || "active"),
         {:ok, automation_job_id} <- optional_positive_integer(attrs, "automation_job_id"),
         payload = Attrs.map_value(attrs, "payload") || %{},
         :ok <- validate_cron_task(payload, automation_job_id),
         {:ok, next_fire_at} <- Planner.next_fire_after(schedule, timezone, now),
         :ok <- reject_exhausted_bound(schedule, next_fire_at) do
      {:ok,
       %{
         status: status,
         agent_uid: agent_uid,
         owner_session_id: owner_session_id,
         binding_name: binding_name,
         name: name,
         schedule: schedule,
         timezone: timezone,
         payload: payload,
         delivery: delivery,
         next_fire_at: next_fire_at_for_status(status, next_fire_at),
         idempotency_key: idempotency_key,
         created_by: Keyword.get(opts, :created_by) || %{"kind" => "operator_api"},
         automation_job_id: automation_job_id
       }}
    end
  end

  @spec cron_schedule_update_attrs(CronSchedule.t(), map(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cron_schedule_update_attrs(%CronSchedule{} = existing, attrs, _now, opts) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with :ok <- validate_cron_update_fields(attrs),
         {:ok, name} <- normalize_updated_name(attrs),
         {:ok, schedule, timezone} <- normalize_updated_schedule(existing, attrs, opts),
         {:ok, delivery} <- normalize_updated_delivery(existing, attrs),
         {:ok, payload} <- normalize_updated_payload(attrs),
         {:ok, automation_job_id} <- normalize_updated_automation_job_id(attrs),
         :ok <-
           validate_cron_task(
             effective_updated_value(attrs, "payload", payload, existing.payload),
             effective_updated_value(
               attrs,
               "automation_job_id",
               automation_job_id,
               existing.automation_job_id
             )
           ) do
      changes =
        %{}
        |> Attrs.maybe_put(:name, name)
        |> maybe_put_updated_schedule(attrs, schedule, timezone)
        |> Attrs.maybe_put(:payload, payload)
        |> Attrs.maybe_put(:delivery, delivery)
        |> maybe_put_automation_job_id(attrs, automation_job_id)

      {:ok, changes}
    end
  end

  defp next_fire_at_for_status("active", %DateTime{} = next_fire_at), do: next_fire_at
  defp next_fire_at_for_status(_status, _next_fire_at), do: nil

  # A schedule whose cutoff precedes its first occurrence would complete without
  # ever firing; that is a caller error, not a schedule.
  defp reject_exhausted_bound(schedule, %DateTime{} = first_fire_at) do
    case Planner.occurrences_bound(schedule) do
      {:until, until} ->
        if DateTime.compare(first_fire_at, until) == :gt,
          do: {:error, :schedule_occurrences_exhausted},
          else: :ok

      _count_or_none ->
        :ok
    end
  end

  defp normalize_cron_status(status) when status in ["active", "paused"], do: {:ok, status}
  defp normalize_cron_status(_status), do: {:error, :invalid_cron_status}

  # A cron execution session cannot own schedules: cron-origin turns are
  # already denied schedule mutation, so an owner in that namespace would be
  # a schedule nothing can manage.
  defp reject_reserved_owner_session("cron:" <> _rest),
    do: {:error, :cron_owner_session_reserved}

  defp reject_reserved_owner_session(_owner_session_id), do: :ok

  # A direct-Agent cron runs in its own execution session and must not depend
  # on the owner conversation's transcript, so its stored input has to carry
  # the whole repeatable instruction. An AutomationJob consumer brings its own
  # committed script instead.
  @doc false
  @spec validate_cron_task(map(), integer() | nil) :: :ok | {:error, :cron_task_required}
  def validate_cron_task(payload, automation_job_id) do
    cond do
      is_integer(automation_job_id) -> :ok
      is_map(payload) and is_binary(payload["task"]) and String.trim(payload["task"]) != "" -> :ok
      true -> {:error, :cron_task_required}
    end
  end

  defp effective_updated_value(attrs, key, normalized, existing) do
    if Map.has_key?(attrs, key), do: normalized, else: existing
  end

  defp validate_cron_update_fields(attrs) do
    allowed = ~w(name schedule timezone payload delivery automation_job_id)

    case Map.keys(attrs) -- allowed do
      _unknown when map_size(attrs) == 0 ->
        {:error, :cron_schedule_update_required}

      [] ->
        :ok

      fields ->
        {:error, {:unknown_cron_schedule_update_fields, Enum.sort(fields)}}
    end
  end

  defp normalize_updated_name(attrs) do
    case Map.fetch(attrs, "name") do
      {:ok, _value} -> Attrs.required_text(attrs, "name")
      :error -> {:ok, nil}
    end
  end

  defp normalize_updated_schedule(existing, attrs, opts) do
    schedule_input =
      case {Map.fetch(attrs, "schedule"), Map.fetch(attrs, "timezone")} do
        {{:ok, schedule}, _timezone} -> schedule
        {:error, {:ok, timezone}} -> Map.put(existing.schedule, "timezone", timezone)
        {:error, :error} -> existing.schedule
      end

    base = %{"timezone" => Map.get(attrs, "timezone", existing.timezone)}
    Planner.normalize_schedule_json(schedule_input, base, opts)
  end

  defp normalize_updated_delivery(existing, attrs) do
    case Map.fetch(attrs, "delivery") do
      {:ok, delivery} -> Delivery.merge_update(existing.delivery, delivery, existing.binding_name)
      :error -> {:ok, nil}
    end
  end

  defp normalize_updated_payload(attrs) do
    case Map.fetch(attrs, "payload") do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :invalid_cron_payload}
      :error -> {:ok, nil}
    end
  end

  defp normalize_updated_automation_job_id(attrs) do
    optional_positive_integer(attrs, "automation_job_id")
  end

  defp maybe_put_automation_job_id(changes, attrs, automation_job_id) do
    if Map.has_key?(attrs, "automation_job_id"),
      do: Map.put(changes, :automation_job_id, automation_job_id),
      else: changes
  end

  defp maybe_put_updated_schedule(changes, attrs, schedule, timezone) do
    if Map.has_key?(attrs, "schedule") or Map.has_key?(attrs, "timezone") do
      changes
      |> Map.put(:schedule, schedule)
      |> Map.put(:timezone, timezone)
    else
      changes
    end
  end

  defp optional_boolean(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_boolean, key}}
      :error -> {:ok, default}
    end
  end

  defp optional_positive_integer(attrs, key) do
    case Map.fetch(attrs, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value > 0 and value <= 9_007_199_254_740_991 ->
        {:ok, value}

      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 and integer <= 9_007_199_254_740_991 ->
            {:ok, integer}

          _invalid ->
            {:error, {:invalid_positive_integer, key}}
        end

      {:ok, _value} ->
        {:error, {:invalid_positive_integer, key}}
    end
  end
end
