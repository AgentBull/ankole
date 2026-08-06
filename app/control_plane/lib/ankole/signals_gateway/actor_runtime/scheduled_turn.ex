defmodule Ankole.SignalsGateway.ActorRuntime.ScheduledTurn do
  @moduledoc false

  import Ecto.Query
  import Ankole.SignalsGateway.ActorRuntime.Common

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.OutboxEntry

  # How many previous fires the identical-reply detection reads. The streak
  # only has to prove "consecutive", not measure history, so a short bounded
  # scan is enough.
  @identical_reply_scan_limit 5

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

    context = %{
      "turn_mode" => scheduled_turn_mode(type),
      "schedule_origin" =>
        reject_nil_values(%{
          "schedule_kind" => map_text(data, "schedule_kind"),
          "due_at" => map_text(data, "due_at"),
          "fired_at" => map_text(data, "fired_at"),
          "timezone" => map_text(data, "timezone"),
          "cron_schedule_name" => map_text(wake_payload, "cron_schedule_name"),
          "cron_fire_slot_at" => map_text(data, "cron_fire_slot_at"),
          "trigger" => map_text(wake_payload, "trigger"),
          "payload" => map_value(wake_payload, "payload") || %{}
        }),
      "silent_success_allowed" => silent_success_allowed?(input)
    }

    case consecutive_identical_replies(input) do
      streak when streak >= 2 -> Map.put(context, "consecutive_identical_replies", streak)
      _short -> context
    end
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

  @doc """
  Counts how many previous fires of this cron schedule produced one identical
  visible reply.

  The model cannot be trusted to notice its own repetition across scheduled
  turns, so the control plane detects it and the turn context carries the
  deterministic fact. Replies are compared with digits, URLs, and whitespace
  runs removed, so timestamps and log links do not hide an identical failure
  notice. The count covers the newest previous fires only and stops at the
  first different or missing reply; anything below two is not a streak and
  adds no context field.
  """
  @spec consecutive_identical_replies(ActorEvent.t()) :: non_neg_integer()
  def consecutive_identical_replies(%ActorEvent{type: "cron.fire"} = input) do
    wake_payload = input |> actor_event_data() |> map_value("wake_payload") || %{}

    case map_text(wake_payload, "cron_schedule_name") do
      nil -> 0
      name -> identical_reply_streak(input, name)
    end
  end

  def consecutive_identical_replies(%ActorEvent{}), do: 0

  defp identical_reply_streak(%ActorEvent{} = input, schedule_name) do
    replies =
      ActorEvent
      |> where([event], event.agent_uid == ^input.agent_uid)
      |> where([event], event.session_id == ^input.session_id)
      |> where([event], event.type == "cron.fire")
      |> where([event], event.id != ^input.id)
      |> where(
        [event],
        fragment("? #>> '{data,wake_payload,cron_schedule_name}'", event.payload) ==
          ^schedule_name
      )
      |> order_by([event], desc: event.queue_sequence)
      |> limit(@identical_reply_scan_limit)
      |> Repo.all()
      |> Enum.map(&fire_reply_text/1)

    case replies do
      [latest | _rest] when is_binary(latest) ->
        anchor = normalize_reply(latest)

        replies
        |> Enum.take_while(&(is_binary(&1) and normalize_reply(&1) == anchor))
        |> length()

      _no_reply ->
        0
    end
  end

  defp fire_reply_text(%ActorEvent{id: event_id}) do
    OutboxEntry
    |> where([entry], entry.source_actor_event_id == ^event_id)
    |> where([entry], not is_nil(entry.fallback_visible_text))
    |> order_by([entry], desc: entry.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      %OutboxEntry{fallback_visible_text: text} -> text
      nil -> nil
    end
  end

  defp normalize_reply(text) do
    text
    |> String.replace(~r{https?://\S+}u, "")
    |> String.replace(~r/\d+/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp actor_event_data(%ActorEvent{payload: payload}) when is_map(payload) do
    map_value(payload, "data") || %{}
  end

  defp actor_event_data(_event), do: %{}
end
