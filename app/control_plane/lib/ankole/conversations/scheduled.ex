defmodule Ankole.Conversations.Scheduled do
  @moduledoc false

  import Ecto.Query
  import Ankole.SignalsGateway.ActorRuntime.Common, only: [reject_nil_values: 1]

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIReplyText
  alias Ankole.SignalsGateway.OutboxEntry

  # How many previous fires the identical-reply detection reads. The streak
  # only has to prove "consecutive", not measure history, so a short bounded
  # scan is enough.
  @identical_reply_scan_limit 5

  def reminder(event) do
    Enum.join(
      [
        "End this scheduled turn with one JSON object that matches scheduled_turn_result. Free-form final text and text control markers are invalid, even if an older task instruction asks for them.",
        "For a visible result, return {\"outcome\":\"reply\",\"reply\":\"the user-visible message\"}. A failed or blocked check, required human action, material change, or time-sensitive risk requires this outcome.",
        if(silent_success_allowed?(event),
          do:
            "If no visible update is useful, return {\"outcome\":\"silent_success\",\"reply\":null}.",
          else: "Silent success is not allowed for this turn. Return a concise visible result."
        ),
        "Do not repeat completed tool actions."
      ],
      "\n"
    )
  end

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

  defp scheduled_turn_context(%ActorEvent{} = input) do
    data = actor_event_data(input)
    wake_payload = map_value(data, "wake_payload") || %{}

    context = %{
      "schedule_origin" =>
        reject_nil_values(%{
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

  def project_completion(%ActorEvent{type: type} = event, completion, outcome)
      when type in ["cron.fire", "check_back_later.wakeup"] do
    text =
      case Map.get(completion, :final_response) do
        %{content: content} -> AIReplyText.visible_text(content)
        _ -> nil
      end

    case {outcome, reply_result(event, text)} do
      {"silent", {:ok, :silent}} ->
        {:ok, %{completion | final_text: nil}}

      {outcome, {:ok, {:reply, text}}} when outcome != "silent" ->
        {:ok, %{completion | final_text: text}}

      {outcome, :empty} when outcome != "silent" ->
        if is_map(completion.clarify_prompt) or completion.attachments != [],
          do: {:ok, completion},
          else: {:error, :invalid_scheduled_reply}

      {_, {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :invalid_scheduled_reply}
    end
  end

  def project_completion(%ActorEvent{}, completion, _outcome), do: {:ok, completion}

  @spec reply_result(ActorEvent.t(), String.t() | nil) ::
          {:ok, :silent | {:reply, String.t()}}
          | :empty
          | {:error, :invalid_scheduled_reply | :schedule_silent_success_not_allowed}
  def reply_result(event, text) do
    case decode_reply(text) do
      {:ok, %{"outcome" => "reply", "reply" => reply}} when is_binary(reply) ->
        case AIReplyText.normalize_visible_text(reply) do
          "" -> {:error, :invalid_scheduled_reply}
          text -> {:ok, {:reply, text}}
        end

      {:ok, %{"outcome" => "silent_success", "reply" => nil}} ->
        if silent_success_allowed?(event),
          do: {:ok, :silent},
          else: {:error, :schedule_silent_success_not_allowed}

      :empty ->
        :empty

      _ ->
        {:error, :invalid_scheduled_reply}
    end
  end

  defp decode_reply(nil), do: :empty

  defp decode_reply(text) do
    case Ankole.JSON.decode(text) do
      {:ok, %{"outcome" => _, "reply" => _} = result} when map_size(result) == 2 ->
        {:ok, result}

      _ ->
        :invalid
    end
  end

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

  defp map_text(map, key) do
    case map_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil
end
