defmodule Ankole.Plugins.SlackAdapter.BlockKit do
  @moduledoc false

  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.SlackAdapter.Mrkdwn
  alias Ankole.I18n
  alias Ankole.SignalsGateway.ReplyPresentation

  @spec render(map()) :: {:ok, [map()]} | {:error, :missing_card_payload}
  def render(payload) when is_map(payload) do
    cond do
      notice = Map.get(payload, "control_notice") ->
        {:ok, notice_blocks(notice, false)}

      notice = Map.get(payload, "progress_notice") ->
        {:ok, notice_blocks(notice, true)}

      is_list(Map.get(payload, "slack_native_blocks")) ->
        {:ok, payload["slack_native_blocks"]}

      is_map(Map.get(payload, "reply_presentation")) ->
        render_reply_presentation(payload["reply_presentation"])

      is_map(Map.get(payload, "interactive_output")) ->
        render_interactive(payload["interactive_output"])

      true ->
        {:error, :missing_card_payload}
    end
  end

  @spec split_blocks([map()]) :: [[map()]]
  def split_blocks(blocks), do: Enum.chunk_every(blocks, 50)

  defp notice_blocks(notice, progress?) do
    text = notice_text(notice)

    context = %{
      "type" => "context",
      "elements" => [%{"type" => "mrkdwn", "text" => Mrkdwn.from_markdown(text)}]
    }

    if progress?, do: [%{"type" => "divider"}, context], else: [context]
  end

  defp notice_text(notice) when is_binary(notice), do: notice

  defp notice_text(notice) when is_map(notice),
    do: Map.get(notice, "text") || Map.get(notice, "message") || ""

  defp notice_text(_notice), do: ""

  defp render_interactive(output) do
    blocks =
      []
      |> add_title(MapHelpers.optional_text(output, "title"))
      |> add_body(body_text(output))
      |> add_facts(MapHelpers.fetch_list(output, "facts"))
      |> add_choices(MapHelpers.fetch_list(output, "choices"))
      |> add_state(MapHelpers.optional_text(output, "state"))

    {:ok, blocks}
  end

  defp render_reply_presentation(presentation) do
    blocks =
      []
      |> add_status(presentation)
      |> add_trigger_context(Map.get(presentation, "trigger_context"))
      |> add_plan(Map.get(presentation, "plan"))
      |> add_activities(Map.get(presentation, "activities", %{}))
      |> add_thought(MapHelpers.optional_text(presentation, "thought"))
      |> add_reply_body(presentation)
      |> add_results(MapHelpers.fetch_list(presentation, "results"))
      |> add_receipts(MapHelpers.fetch_list(presentation, "receipts"))
      |> add_interaction_result(presentation)
      |> add_presentation_actions(presentation)

    {:ok,
     if(blocks == [], do: [section(I18n.t("signals_gateway.reply.no_content"))], else: blocks)}
  end

  defp add_status(blocks, presentation) do
    state = Map.get(presentation, "state")
    configured = get_in(presentation, ["meta", "status"])

    text =
      cond do
        state == "completed" ->
          nil

        state == "failed" ->
          ":warning: " <> reply_text("failed")

        state == "stopped" ->
          ":stop_sign: " <> reply_text("stopped")

        state == "awaiting_input" ->
          ":speech_balloon: " <> reply_text("awaiting_input")

        state == "scheduled" ->
          ":clock3: " <> reply_text("scheduled")

        is_binary(configured) and String.trim(configured) != "" ->
          status_icon(state) <> configured

        state == "working" ->
          ":hourglass_flowing_sand: " <> reply_text("working")

        state == "debouncing" ->
          ":hourglass_flowing_sand: " <> reply_text("debouncing")

        true ->
          nil
      end

    add_context(blocks, text)
  end

  defp status_icon(_state), do: ":hourglass_flowing_sand: "

  defp reply_text(key), do: I18n.t("plugins.slack_adapter.reply.#{key}")

  defp add_trigger_context(blocks, %{"kind" => "background_agent_job_failure"} = context) do
    title = MapHelpers.optional_text(context, "title") || "Background Agent Job failed"
    summary = MapHelpers.optional_text(context, "summary")
    add_body(blocks, join_text(["*:warning: #{title}*", summary]))
  end

  defp add_trigger_context(blocks, %{"kind" => "scheduled_task"}),
    do: add_context(blocks, ":clock3: Scheduled task")

  defp add_trigger_context(blocks, _context), do: blocks

  defp add_plan(blocks, %{"items" => items}) when is_list(items) and items != [] do
    text =
      items
      |> Enum.map(fn item ->
        icon = plan_icon(Map.get(item, "status"))
        "#{icon} #{Map.get(item, "content", "")}" |> String.trim()
      end)
      |> Enum.join("\n")

    add_body(blocks, "*Plan*\n" <> text)
  end

  defp add_plan(blocks, _plan), do: blocks

  defp plan_icon("completed"), do: ":white_check_mark:"
  defp plan_icon("in_progress"), do: ":arrow_forward:"
  defp plan_icon("cancelled"), do: ":no_entry_sign:"
  defp plan_icon(_status), do: ":white_circle:"

  defp add_activities(blocks, activities) when is_map(activities) and map_size(activities) > 0 do
    text =
      activities
      |> Map.values()
      |> Enum.sort_by(&{Map.get(&1, "phase", ""), Map.get(&1, "operation_id", "")})
      |> Enum.map(fn activity ->
        "#{activity_icon(Map.get(activity, "phase"))} #{Map.get(activity, "label", "")}"
        |> String.trim()
      end)
      |> Enum.join("\n")

    add_body(blocks, text)
  end

  defp add_activities(blocks, _activities), do: blocks

  defp activity_icon("completed"), do: ":white_check_mark:"
  defp activity_icon("failed"), do: ":x:"
  defp activity_icon("pending"), do: ":white_circle:"
  defp activity_icon(_phase), do: ":hourglass_flowing_sand:"

  defp add_thought(blocks, nil), do: blocks

  defp add_thought(blocks, thought) do
    quoted = thought |> String.split("\n") |> Enum.map_join("\n", fn line -> "> " <> line end)
    add_body(blocks, quoted)
  end

  defp add_reply_body(blocks, presentation) do
    text =
      case Map.get(presentation, "state") do
        "awaiting_input" ->
          MapHelpers.optional_text(presentation, "prompt") ||
            MapHelpers.optional_text(presentation, "answer")

        _state ->
          MapHelpers.optional_text(presentation, "answer")
      end

    add_body(blocks, text)
  end

  defp add_results(blocks, results) do
    Enum.reduce(results, blocks, fn result, acc -> add_result(acc, result) end)
  end

  defp add_result(blocks, %{"kind" => "artifact", "name" => name, "url" => url} = result) do
    description = MapHelpers.optional_text(result, "description")
    add_body(blocks, join_text(["**:paperclip: [#{escape_label(name)}](#{url})**", description]))
  end

  defp add_result(blocks, %{"kind" => "image"} = result) do
    label = MapHelpers.optional_text(result, "caption") || Map.get(result, "alt") || "Image"
    add_body(blocks, ":frame_with_picture: #{label}")
  end

  defp add_result(blocks, %{"kind" => "table"} = result) do
    add_body(blocks, render_table(result))
  end

  defp add_result(blocks, %{"kind" => "chart"} = result) do
    title = MapHelpers.optional_text(result, "title") || "Chart"
    takeaway = MapHelpers.optional_text(result, "takeaway")
    add_body(blocks, join_text(["*:bar_chart: #{title}*", takeaway]))
  end

  defp add_result(blocks, %{"kind" => "metrics"} = result) do
    metrics =
      result
      |> MapHelpers.fetch_list("metrics")
      |> Enum.map_join("  •  ", fn metric ->
        "*#{Map.get(metric, "label", "")}:* #{Map.get(metric, "value", "")}#{Map.get(metric, "unit", "")}"
      end)

    add_body(blocks, metrics)
  end

  defp add_result(blocks, _result), do: blocks

  defp render_table(%{"columns" => columns, "rows" => rows})
       when is_list(columns) and is_list(rows) do
    header = Enum.map_join(columns, " | ", &Map.get(&1, "label", ""))

    body =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(columns, " | ", fn column -> to_string(Map.get(row, column["key"], "")) end)
      end)

    "```\n" <> join_text([header, body]) <> "\n```"
  end

  defp render_table(_result), do: nil

  defp add_receipts(blocks, receipts) do
    text =
      receipts
      |> Enum.map_join("\n", fn receipt ->
        scope = if is_binary(receipt["scope"]), do: " (#{receipt["scope"]})", else: ""
        ":white_check_mark: #{Map.get(receipt, "summary", "")}#{scope}"
      end)

    add_body(blocks, blank_to_nil(text))
  end

  defp add_interaction_result(blocks, %{"interaction_status" => "answered"} = presentation) do
    add_context(blocks, ":white_check_mark: #{presentation["interaction_answer"] || "Answered"}")
  end

  defp add_interaction_result(blocks, %{"interaction_status" => "superseded"}),
    do: add_context(blocks, ":no_entry_sign: This question is no longer active")

  defp add_interaction_result(blocks, _presentation), do: blocks

  defp add_presentation_actions(blocks, %{
         "interaction_status" => "pending",
         "actions" => actions
       })
       when is_list(actions) do
    {buttons, forms} = Enum.split_with(actions, &(&1["type"] == "button"))

    blocks
    |> add_reply_buttons(buttons)
    |> add_free_text_hint(forms)
  end

  defp add_presentation_actions(blocks, _presentation), do: blocks

  defp add_reply_buttons(blocks, buttons) do
    actions =
      buttons
      |> Enum.reject(&(&1["disabled"] == true))
      |> Enum.flat_map(&reply_button/1)
      |> Enum.chunk_every(5)
      |> Enum.map(&%{"type" => "actions", "elements" => &1})

    blocks ++ actions
  end

  defp reply_button(
         %{
           "source_actor_event_id" => source_actor_event_id,
           "control_id" => control_id,
           "selected_option_id" => selected_option_id
         } = action
       )
       when is_binary(source_actor_event_id) and is_binary(control_id) and
              is_binary(selected_option_id) do
    case ReplyPresentation.callback_value(source_actor_event_id, action) do
      {:ok, value} ->
        [
          %{
            "type" => "button",
            "action_id" => truncate("ankole:choice:#{control_id}:#{selected_option_id}", 255),
            "text" => %{"type" => "plain_text", "text" => truncate(action["label"], 75)},
            "value" => Torque.encode!(value)
          }
          |> maybe_put_button_style(action["style"])
        ]

      {:error, :invalid_callback_action} ->
        []
    end
  end

  defp reply_button(_action), do: []

  defp maybe_put_button_style(button, "primary"), do: Map.put(button, "style", "primary")
  defp maybe_put_button_style(button, "danger"), do: Map.put(button, "style", "danger")
  defp maybe_put_button_style(button, _style), do: button

  defp add_free_text_hint(blocks, forms) do
    if Enum.any?(forms, &(&1["disabled"] != true)) do
      add_context(blocks, "Reply in this thread with your answer.")
    else
      blocks
    end
  end

  defp add_title(blocks, nil), do: blocks

  defp add_title(blocks, title) do
    blocks ++
      [%{"type" => "header", "text" => %{"type" => "plain_text", "text" => truncate(title, 150)}}]
  end

  defp body_text(output) do
    MapHelpers.optional_text(output, "body") ||
      MapHelpers.optional_text(output, "text") ||
      MapHelpers.optional_text(output, "fallback_visible_text")
  end

  defp add_body(blocks, nil), do: blocks

  defp add_body(blocks, body) do
    sections =
      body
      |> Mrkdwn.from_markdown()
      |> split_text(3_000)
      |> Enum.map(&%{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => &1}})

    blocks ++ sections
  end

  defp add_facts(blocks, facts) do
    sections =
      facts
      |> Enum.map(fn fact ->
        label = Map.get(fact, "label", "")
        value = Map.get(fact, "value", "")
        %{"type" => "mrkdwn", "text" => "*#{label}*\n#{Mrkdwn.from_markdown(to_string(value))}"}
      end)
      |> Enum.chunk_every(10)
      |> Enum.map(&%{"type" => "section", "fields" => &1})

    blocks ++ sections
  end

  defp add_choices(blocks, choices) do
    actions =
      choices
      |> Enum.map(fn choice ->
        value = to_string(Map.get(choice, "value", ""))

        %{
          "type" => "button",
          "action_id" => "ankole:choice:" <> value,
          "text" => %{
            "type" => "plain_text",
            "text" => truncate(to_string(Map.get(choice, "label", value)), 75)
          },
          "value" =>
            Torque.encode!(%{"v" => ReplyPresentation.action_protocol(), "value" => value})
        }
      end)
      |> Enum.chunk_every(5)
      |> Enum.map(&%{"type" => "actions", "elements" => &1})

    blocks ++ actions
  end

  defp add_state(blocks, nil), do: blocks

  defp add_state(blocks, state) do
    blocks ++
      [
        %{
          "type" => "context",
          "elements" => [%{"type" => "mrkdwn", "text" => Mrkdwn.from_markdown(state)}]
        }
      ]
  end

  defp add_context(blocks, nil), do: blocks

  defp add_context(blocks, text) do
    blocks ++
      [
        %{
          "type" => "context",
          "elements" => [%{"type" => "mrkdwn", "text" => Mrkdwn.from_markdown(text)}]
        }
      ]
  end

  defp section(text),
    do: %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}

  defp join_text(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_text), do: nil

  defp escape_label(text), do: text |> to_string() |> String.replace(["<", ">", "|"], "")

  defp split_text(text, size) do
    text |> String.graphemes() |> Enum.chunk_every(size) |> Enum.map(&Enum.join/1)
  end

  defp truncate(text, size), do: String.slice(text, 0, size)
end
