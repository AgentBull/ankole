defmodule Ankole.Sessions.Scheduled do
  @moduledoc false
  use Ankole.Sessions.RunType
  @behaviour Ankole.Sessions.Tool

  import Ankole.Sessions.Common, only: [reject_nil_values: 1]
  import Ash.Expr, only: [expr: 1]

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.Text

  # How many previous fires the identical-reply detection reads. The streak
  # only has to prove "consecutive", not measure history, so a short bounded
  # scan is enough.
  @identical_reply_scan_limit 5

  @doc "Checks whether a completed schedule fire produced this exact Signal."
  @spec produced_signal?(Signal.t() | term()) :: boolean()
  def produced_signal?(%Signal{
        producer: :kernel,
        id: id,
        agent_uid: agent,
        session_id: session,
        type: type
      })
      when is_binary(id) and is_binary(agent) and is_binary(session) and
             type in ["cron.fire", "check_back_later.wakeup"] do
    kind = if type == "cron.fire", do: "cron_fire", else: "check_back_later"

    [
      query: [
        filter: [
          signal_id: id,
          agent_uid: agent,
          session_id: session,
          kind: kind,
          status: :fired,
          fired_at: [is_nil: false]
        ],
        select: [:id],
        limit: 1
      ]
    ]
    |> Ankole.Schedule.list_scheduled_events!()
    |> Enum.any?()
  end

  def produced_signal?(_event), do: false

  def plan(event, opts), do: {:ok, %{kind: :scheduled, opts: __MODULE__.opts(event, opts)}}
  def nudge?, do: false
  def repair(_run, _text), do: nil

  def instructions(run) do
    super(run) <>
      "\nFinish this scheduled turn by calling finish_scheduled. Use outcome reply with the final visible text. Use silent_success with a null reply only when silent_success_allowed is true and the check succeeded without anything useful to report."
  end

  def failure(reason)
      when reason in [
             :invalid_scheduled_reply,
             :scheduled_turn_not_finished,
             :schedule_silent_success_not_allowed
           ] do
    {:execution_error,
     %{
       "code" => Atom.to_string(reason),
       "message" => "The model result did not satisfy the scheduled completion contract.",
       "retryable" => false
     }}
  end

  def failure(reason), do: super(reason)

  def declarations do
    [
      %{
        "type" => "function",
        "name" => "finish_scheduled",
        "run_kinds" => ["scheduled"],
        "ends_run" => true,
        "description" =>
          "End this scheduled turn. Use reply for a visible result, a failed or blocked check, required human action, or a material change. Use silent_success only when this schedule allows quiet success and no update is useful.",
        "execution_mode" => "sequential",
        "executor" => __MODULE__,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "outcome" => %{"type" => "string", "enum" => ["reply", "silent_success"]},
            "reply" => %{"type" => ["string", "null"]}
          },
          "required" => ["outcome", "reply"],
          "additionalProperties" => false
        }
      }
    ]
  end

  def normalize("finish_scheduled", args), do: args

  def prepare_in_tx(run, call, args),
    do: {:ok, [], fn -> commit_tool_in_tx(run, call, args) end}

  defp commit_tool_in_tx(run, _call, args) do
    case {args["outcome"], args["reply"]} do
      {"reply", reply} when is_binary(reply) ->
        text = Text.normalize_visible_text(reply)

        if text == "",
          do: {:error, :invalid_scheduled_reply},
          else:
            {:ok,
             Ankole.Sessions.Tools.result(%{"accepted" => true},
               terminate: true,
               outcome: :loop_finished,
               final_text: text
             ), []}

      {"silent_success", nil} ->
        if silent_success_allowed?(run.event),
          do:
            {:ok,
             Ankole.Sessions.Tools.result(%{"accepted" => true},
               terminate: true,
               outcome: :silent
             ), []},
          else: {:error, :schedule_silent_success_not_allowed}

      _ ->
        {:error, :invalid_scheduled_reply}
    end
  end

  def opts(%Signal{type: type} = input, opts) do
    base_context = Keyword.get(opts, :request_context, %{})
    schedule_context = scheduled_turn_context(input)

    Keyword.merge(opts,
      kind: scheduled_turn_kind(type),
      request_context: Map.merge(base_context, schedule_context)
    )
  end

  defp scheduled_turn_kind("check_back_later.wakeup"), do: "checkback_generation"
  defp scheduled_turn_kind("cron.fire"), do: "scheduled_task"

  defp scheduled_turn_context(%Signal{} = input) do
    data = signal_data(input)
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

  @spec silent_success_allowed?(Signal.t()) :: boolean()
  def silent_success_allowed?(%Signal{producer: :kernel, type: "check_back_later.wakeup"} = event) do
    wake_payload = event |> signal_data() |> map_value("wake_payload")
    map_value(wake_payload, "quiet_success") == true
  end

  def silent_success_allowed?(%Signal{producer: :kernel, type: "cron.fire"} = event) do
    wake_payload = event |> signal_data() |> map_value("wake_payload")
    delivery = map_value(wake_payload, "delivery")
    map_value(delivery, "quiet_success") == true
  end

  def silent_success_allowed?(%Signal{}), do: false

  def project_completion(%{kind: :scheduled} = run, completion) do
    result =
      Enum.find_value(run.round_calls, fn call ->
        result = run.results[Ankole.Sessions.Run.call_id(call)]
        if result && Ankole.Sessions.ToolResult.ends_turn?(result), do: result
      end)

    case result do
      %{final_text: text} when is_binary(text) and text != "" ->
        {:ok, %{completion | final_text: text}}

      _ ->
        text = Text.normalize_visible_text(completion.final_text || "")

        if text == "",
          do: {:error, :scheduled_turn_not_finished},
          else: {:ok, %{completion | final_text: text}}
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
  @spec consecutive_identical_replies(Signal.t()) :: non_neg_integer()
  def consecutive_identical_replies(%Signal{producer: :kernel, type: "cron.fire"} = input) do
    wake_payload = input |> signal_data() |> map_value("wake_payload") || %{}

    case map_text(wake_payload, "cron_schedule_name") do
      nil -> 0
      name -> identical_reply_streak(input, name)
    end
  end

  def consecutive_identical_replies(%Signal{}), do: 0

  defp identical_reply_streak(%Signal{} = input, schedule_name) do
    signal_ids =
      [
        query: [
          filter:
            expr(
              agent_uid == ^input.agent_uid and session_id == ^input.session_id and
                type == "cron.fire" and producer == :kernel and id != ^input.id and
                fragment("? #>> '{wake_payload,cron_schedule_name}'", data) == ^schedule_name
            ),
          sort: [queue_sequence: :desc],
          limit: @identical_reply_scan_limit,
          select: [:id]
        ]
      ]
      |> Ankole.Signals.list_signals!()
      |> Enum.map(& &1.id)

    candidates = Ankole.Conversations.reply_candidate_texts(signal_ids)
    replies = Enum.map(signal_ids, &Map.get(candidates, &1))

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

  defp normalize_reply(text) do
    text
    |> String.replace(~r{https?://\S+}u, "")
    |> String.replace(~r/\d+/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp signal_data(%Signal{data: data}) when is_map(data), do: data

  defp signal_data(_event), do: %{}

  defp map_text(map, key), do: map |> map_value(key) |> Ankole.Attrs.optional_text()

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil
end
