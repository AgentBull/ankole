defmodule Ankole.Plugins.LarkAdapter.CardKit.Renderer do
  @moduledoc """
  Pure CardKit JSON 2.0 renderer for provider-neutral reply presentations.

  The renderer accepts only the closed `ReplyPresentation` shape. It never
  interprets tool stdout or arbitrary model/provider JSON as a component.
  """

  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.Plugins.LarkAdapter.CardKit.I18n, as: CardI18n

  @soft_bytes 24 * 1_024
  @soft_elements 160
  @action_value_version "ankole.interactive_output.action.v1"
  @metadata_element_ids ~w(state receipts plan thought activity meta)
  @separator_id "separator"

  @spec render(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def render(presentation, opts \\ []) do
    mode = Keyword.get(opts, :mode, :working)
    presentation = presentation |> normalize_for_mode(mode) |> scope_to_page(opts)
    elements = elements(presentation, mode)

    card = %{
      "schema" => "2.0",
      "config" => config(presentation, mode),
      "body" => %{
        "direction" => "vertical",
        "horizontal_spacing" => "8px",
        "vertical_spacing" => "8px",
        "horizontal_align" => "left",
        "vertical_align" => "top",
        "padding" => "12px 12px 12px 12px",
        "elements" => elements
      }
    }

    validate_budget(card, mode)
  end

  @doc """
  Builds a single CardKit batch-update action list from two semantic snapshots.
  """
  @spec batch_actions(map(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def batch_actions(previous, current, opts \\ []) do
    mode = Keyword.get(opts, :mode, :working)
    previous_opts = Keyword.get(opts, :previous, [])
    current_opts = Keyword.get(opts, :current, [])

    with {:ok, previous_card} <-
           render(previous, Keyword.put(previous_opts, :mode, previous_mode(previous, mode))),
         {:ok, current_card} <- render(current, Keyword.put(current_opts, :mode, mode)) do
      previous_elements = get_in(previous_card, ["body", "elements"])
      current_elements = get_in(current_card, ["body", "elements"])
      previous_by_id = index_elements(previous_elements)
      current_by_id = index_elements(current_elements)
      previous_ids = previous_element_ids(previous_by_id, opts)
      current_ids = Map.keys(current_by_id) |> MapSet.new()

      removed = MapSet.difference(previous_ids, current_ids) |> MapSet.to_list()
      common = MapSet.intersection(previous_ids, current_ids) |> MapSet.to_list()
      added_ids = MapSet.difference(current_ids, previous_ids)

      actions =
        []
        |> maybe_delete(removed)
        |> append_updates(common, previous_by_id, current_by_id)
        |> append_additions(current_elements, added_ids)

      {:ok, actions}
    end
  end

  @spec element_ids(map(), keyword()) :: [String.t()]
  def element_ids(presentation, opts \\ []) do
    case render(presentation, opts) do
      {:ok, card} -> card |> get_in(["body", "elements"]) |> Enum.map(& &1["element_id"])
      {:error, _reason} -> []
    end
  end

  @spec answer_content(map(), keyword()) :: String.t()
  def answer_content(presentation, opts \\ []) do
    case render(presentation, opts) do
      {:ok, card} ->
        card
        |> get_in(["body", "elements"])
        |> Enum.find(&(&1["element_id"] == "answer"))
        |> case do
          %{"content" => content} when is_binary(content) -> content
          _missing -> " "
        end

      {:error, _reason} ->
        " "
    end
  end

  defp normalize_for_mode(presentation, :terminal) do
    presentation = ReplyPresentation.normalize(presentation)

    if ReplyPresentation.terminal_state?(presentation) do
      presentation
    else
      ReplyPresentation.terminal(presentation, "completed", presentation["answer"])
    end
  end

  defp normalize_for_mode(presentation, _mode), do: ReplyPresentation.normalize(presentation)

  defp previous_mode(previous, :terminal) do
    if ReplyPresentation.terminal_state?(previous), do: :terminal, else: :working
  end

  defp previous_mode(_previous, mode), do: mode

  defp config(presentation, mode) do
    streaming? =
      mode == :working and presentation["state"] in ["debouncing", "working"] and
        presentation["__cardkit_page_tail"] != false

    %{
      "wide_screen_mode" => true,
      "update_multi" => true,
      "streaming_mode" => streaming?,
      "summary" => %{"content" => summary(presentation)},
      "streaming_config" => %{
        "print_frequency_ms" => %{"default" => 70, "android" => 70, "ios" => 70, "pc" => 70},
        "print_step" => %{"default" => 1, "android" => 1, "ios" => 1, "pc" => 1},
        "print_strategy" => "fast"
      }
    }
  end

  defp elements(presentation, mode) do
    metadata =
      []
      |> append(state_element(presentation))
      |> append(receipts_element(presentation))
      |> append(plan_element(presentation, mode))
      |> append(thought_element(presentation, mode))
      |> append(activity_element(presentation, mode))
      |> append(meta_element(presentation))

    primary =
      []
      |> append(trigger_context_element(presentation))
      |> append(answer_element(presentation, mode))
      |> append_all(result_elements(presentation))
      |> append_all(action_elements(presentation, mode))

    metadata ++ separator_elements(metadata, primary) ++ primary
  end

  defp state_element(%{"__cardkit_page_tail" => false} = presentation),
    do: compact_metadata("state", state_copy(presentation), "info_outlined")

  defp state_element(%{"state" => "completed"}), do: nil

  defp state_element(presentation) do
    compact_metadata("state", state_copy(presentation), state_icon(presentation))
  end

  defp state_copy(%{"__cardkit_page_tail" => false}), do: CardI18n.text("continued")

  defp state_copy(%{"state" => "debouncing"}), do: CardI18n.text("debouncing")

  defp state_copy(%{"state" => "working", "answer" => answer}) when answer != "",
    do: CardI18n.text("refining")

  defp state_copy(%{"state" => "working"} = presentation) do
    case get_in(presentation, ["meta", "status"]) do
      status when is_binary(status) and status != "" -> %{"content" => status}
      _missing -> CardI18n.text("working")
    end
  end

  defp state_copy(%{"state" => "awaiting_input", "interaction_status" => "answered"}),
    do: CardI18n.text("answer_received")

  defp state_copy(%{"state" => "awaiting_input", "interaction_status" => "superseded"}),
    do: CardI18n.text("interaction_superseded")

  defp state_copy(%{"state" => "awaiting_input"}), do: CardI18n.text("awaiting_input")

  defp state_copy(%{"state" => "failed"}), do: CardI18n.text("failed")
  defp state_copy(%{"state" => "stopped"}), do: CardI18n.text("stopped")
  defp state_copy(%{"state" => "scheduled"}), do: CardI18n.text("scheduled")
  defp state_copy(_presentation), do: CardI18n.text("working")

  defp plan_element(%{"plan" => %{} = plan}, mode) do
    items = plan["items"] || []
    summary = plan["summary"] || %{}
    completed = summary["completed"] || 0
    total = summary["total"] || length(items)

    visible_items =
      items
      |> plan_window()
      |> Enum.map_join("\n", fn item -> "#{plan_marker(item["status"])} #{item["content"]}" end)

    panel(
      "plan",
      CardI18n.plain_text("plan_title", %{completed: completed, total: total}),
      visible_items,
      "list-check_outlined",
      mode == :working
    )
  end

  defp plan_element(_presentation, _mode), do: nil

  defp thought_element(%{"thought" => thought, "state" => "working"}, :working)
       when is_binary(thought) and thought != "" do
    panel("thought", CardI18n.plain_text("thought_title"), thought, "ai-common_colorful", true)
  end

  defp thought_element(_presentation, _mode), do: nil

  defp trigger_context_element(
         %{
           "trigger_context" =>
             %{
               "kind" => "background_agent_job_failure",
               "title" => title
             } = trigger_context
         } = presentation
       )
       when is_binary(title) do
    if first_cardkit_page?(presentation) do
      summary = trigger_context["summary"]

      key =
        if is_binary(summary) and summary != "",
          do: "background_agent_job_failure_context",
          else: "background_agent_job_failure_context_without_summary"

      bindings = %{
        title: escape_inline(title),
        summary: escape_inline(summary || "")
      }

      %{
        "tag" => "markdown",
        "element_id" => "trigger_context"
      }
      |> Map.merge(CardI18n.text(key, bindings))
    end
  end

  defp trigger_context_element(_presentation), do: nil

  defp answer_element(%{"answer" => ""}, :terminal), do: nil

  defp answer_element(presentation, _mode) do
    answer = presentation["answer"] || ""

    %{
      "tag" => "markdown",
      "element_id" => "answer",
      "content" => if(answer == "", do: " ", else: safe_stream_markdown(answer))
    }
  end

  defp result_elements(%{"results" => results}) when is_list(results) do
    results
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {result, index} -> render_result(result, index) end)
  end

  defp result_elements(_presentation), do: []

  defp render_result(%{"kind" => "table"} = result, index) do
    columns =
      result["columns"]
      |> Enum.with_index(1)
      |> Enum.map(fn {column, column_index} ->
        %{
          "name" => "c#{column_index}",
          "display_name" => column["label"],
          "data_type" => "text",
          "width" => "auto"
        }
      end)

    rows =
      Enum.map(result["rows"], fn row ->
        result["columns"]
        |> Enum.with_index(1)
        |> Map.new(fn {column, column_index} ->
          {"c#{column_index}", row[column["key"]] || ""}
        end)
      end)

    [
      maybe_result_title(result, index),
      %{
        "tag" => "table",
        "element_id" => result_id(index),
        "columns" => columns,
        "rows" => rows,
        "header_style" => %{
          "bold" => true,
          "text_align" => "left",
          "text_size" => "normal",
          "background_style" => "none",
          "text_color" => "default",
          "lines" => 1
        },
        "page_size" => max(1, min(length(rows), 10))
      }
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp render_result(%{"kind" => "chart"} = result, index) do
    values =
      Enum.flat_map(result["series"], fn series ->
        Enum.map(series["points"], fn point ->
          %{"series" => series["name"], "label" => point["label"], "value" => point["value"]}
        end)
      end)

    chart = %{
      "tag" => "chart",
      "element_id" => result_id(index),
      "aspect_ratio" => "16:9",
      "color_theme" => "brand",
      "preview" => true,
      "chart_spec" => %{
        "type" => "line",
        "data" => %{"values" => values},
        "xField" => "label",
        "yField" => "value",
        "seriesField" => "series",
        "legends" => %{"visible" => length(result["series"]) > 1}
      }
    }

    [maybe_result_title(result, index), chart, takeaway_element(result, index)]
    |> Enum.reject(&is_nil/1)
  end

  defp render_result(%{"kind" => "image"} = result, index) do
    [
      maybe_result_title(result, index),
      %{
        "tag" => "img",
        "element_id" => result_id(index),
        "img_key" => result["image_key"],
        "alt" => %{"tag" => "plain_text", "content" => result["alt"]},
        "preview" => true
      },
      caption_element(result, index)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp render_result(%{"kind" => "artifact"} = result, index) do
    label = result["description"] || "打开文件"

    [
      %{
        "tag" => "markdown",
        "element_id" => result_id(index),
        "content" =>
          "**#{escape_inline(result["name"])}**\n\n[#{escape_inline(label)}](#{escape_link_destination(result["url"])})"
      }
    ]
  end

  defp render_result(%{"kind" => "metrics"} = result, index) do
    columns =
      Enum.map(result["metrics"], fn metric ->
        %{
          "tag" => "column",
          "width" => "weighted",
          "weight" => 1,
          "elements" => [
            %{
              "tag" => "markdown",
              "content" =>
                "**#{escape_inline(metric["value"])}**\n#{escape_inline(metric["label"])}"
            }
          ]
        }
      end)

    [
      maybe_result_title(result, index),
      %{"tag" => "column_set", "element_id" => result_id(index), "columns" => columns}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp render_result(_result, _index), do: []

  defp receipts_element(%{"receipts" => receipts}) when is_list(receipts) and receipts != [] do
    content =
      Enum.map_join(receipts, "\n", fn receipt ->
        scope = if receipt["scope"], do: "（#{receipt["scope"]}）", else: ""
        "- ✅ #{receipt["summary"]}#{scope}"
      end)

    panel("receipts", CardI18n.plain_text("receipts_title"), content, "check_outlined", false)
  end

  defp receipts_element(_presentation), do: nil

  defp activity_element(%{"activities" => activities} = presentation, mode)
       when map_size(activities) > 0 do
    ordered =
      activities
      |> Map.values()
      |> Enum.sort_by(& &1["revision"])

    content =
      ordered
      |> Enum.map_join("\n", fn activity ->
        "- #{activity_marker(activity["phase"])} #{escape_markdown_text(activity_label(activity))}"
      end)

    panel(
      "activity",
      activity_title(ordered, mode),
      content,
      "history_outlined",
      mode == :working and not is_map(presentation["plan"])
    )
  end

  defp activity_element(_presentation, _mode), do: nil

  defp activity_title(activities, :working) do
    running = Enum.filter(activities, &(&1["phase"] == "running"))

    case running do
      [] ->
        CardI18n.plain_text("activity_title")

      [activity] ->
        CardI18n.plain_text("activity_title_current", %{
          current: activity |> activity_label() |> truncate(60) |> escape_markdown_text()
        })

      running ->
        latest = List.last(running)

        CardI18n.plain_text("activity_title_parallel", %{
          current: latest |> activity_label() |> truncate(60) |> escape_markdown_text(),
          count: length(running)
        })
    end
  end

  defp activity_title(activities, _mode),
    do: CardI18n.plain_text("activity_title_summary", %{count: length(activities)})

  defp action_elements(%{"actions" => actions} = presentation, mode)
       when is_list(actions) and actions != [] and mode == :terminal do
    buttons = Enum.flat_map(actions, &render_button_action/1)

    button_element =
      case buttons do
        [] ->
          nil

        buttons ->
          %{
            "tag" => "column_set",
            "element_id" => "actions",
            "columns" => [
              %{
                "tag" => "column",
                "width" => "weighted",
                "weight" => 1,
                "vertical_spacing" => "8px",
                "elements" => buttons
              }
            ]
          }
      end

    forms =
      actions
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {action, index} -> render_form_action(action, presentation, index) end)

    elements = [button_element | forms] |> Enum.reject(&is_nil/1)
    if forms == [], do: elements, else: elements ++ [free_input_hint_element()]
  end

  defp action_elements(_presentation, _mode), do: []

  defp render_button_action(
         %{
           "type" => "button",
           "interaction_id" => interaction_id,
           "source_actor_event_id" => source_actor_event_id,
           "control_id" => control_id,
           "selected_option_id" => selected_option_id,
           "option_value" => option_value,
           "revision" => revision
         } = action
       )
       when is_binary(interaction_id) and is_binary(source_actor_event_id) and
              is_binary(control_id) and is_binary(selected_option_id) and
              is_binary(option_value) and is_integer(revision) do
    detailed? = present_text?(action["description"]) or String.length(action["label"]) > 40

    button_text =
      cond do
        action["selected"] == true and detailed? ->
          CardI18n.plain_text("selected_option")

        action["selected"] == true ->
          CardI18n.plain_text("selected_option_with_label", %{label: action["label"]})

        detailed? ->
          CardI18n.plain_text("select_option")

        true ->
          %{"tag" => "plain_text", "content" => action["label"]}
      end

    context = if detailed?, do: choice_context_elements(action), else: []

    context ++
      [
        %{
          "tag" => "button",
          "name" => action["id"],
          "type" => button_type(action["style"]),
          "width" => "fill",
          "disabled" => action["disabled"] == true,
          "text" => button_text,
          "behaviors" => [
            %{
              "type" => "callback",
              "value" => %{
                "version" => @action_value_version,
                "answerKind" => "choice",
                "interactionId" => interaction_id,
                "interactionVersion" => revision,
                "controlId" => control_id,
                "selectedOptionId" => selected_option_id,
                "optionValue" => option_value,
                "sourceActorEventId" => source_actor_event_id
              }
            }
          ]
        }
      ]
  end

  defp render_button_action(_action), do: []

  defp render_form_action(
         %{
           "type" => "form",
           "id" => id,
           "interaction_id" => interaction_id,
           "source_actor_event_id" => source_actor_event_id,
           "control_id" => control_id,
           "revision" => revision,
           "fields" => [%{"type" => "input", "id" => input_name} = field]
         } = action,
         %{"interaction_status" => "pending"},
         index
       )
       when is_binary(id) and is_binary(interaction_id) and
              is_binary(source_actor_event_id) and is_binary(control_id) and
              is_integer(revision) and is_binary(input_name) do
    if action["disabled"] == true do
      []
    else
      [
        %{
          "tag" => "form",
          "element_id" => "action_form#{index}",
          "name" => "#{id}-form",
          "vertical_spacing" => "8px",
          "elements" => [
            render_input_field(field),
            %{
              "tag" => "button",
              "name" => id,
              "type" => button_type(action["style"] || "primary"),
              "width" => "fill",
              "form_action_type" => "submit",
              "text" => CardI18n.plain_text("submit_reply"),
              "behaviors" => [
                %{
                  "type" => "callback",
                  "value" => %{
                    "version" => @action_value_version,
                    "answerKind" => "free_text",
                    "interactionId" => interaction_id,
                    "interactionVersion" => revision,
                    "controlId" => control_id,
                    "inputName" => input_name,
                    "sourceActorEventId" => source_actor_event_id
                  }
                }
              ]
            }
          ]
        }
      ]
    end
  end

  defp render_form_action(_action, _presentation, _index), do: []

  defp render_input_field(field) do
    %{
      "tag" => "input",
      "name" => field["id"],
      "label" => CardI18n.plain_text("free_input_label"),
      "placeholder" => CardI18n.plain_text("free_input_placeholder"),
      "label_position" => "top",
      "width" => "fill",
      "required" => field["required"] == true,
      "input_type" => if(field["multiline"] == true, do: "multiline_text", else: "text"),
      "rows" => if(field["multiline"] == true, do: 3, else: 1),
      "auto_resize" => field["multiline"] == true,
      "max_rows" => if(field["multiline"] == true, do: 6, else: 1),
      "max_length" => field["max_length"] || 1_000,
      "fallback" => %{
        "tag" => "fallback_text",
        "text" => CardI18n.plain_text("free_input_fallback")
      }
    }
  end

  defp choice_context_elements(action) do
    [choice_text(action["label"], "normal", "default")]
    |> append(choice_description(action["description"]))
  end

  defp choice_description(description) when is_binary(description) and description != "",
    do: choice_text(description, "notation", "grey")

  defp choice_description(_description), do: nil

  defp choice_text(content, size, color) do
    %{
      "tag" => "div",
      "text" => %{
        "tag" => "plain_text",
        "content" => content,
        "text_size" => size,
        "text_color" => color
      }
    }
  end

  defp free_input_hint_element do
    %{
      "tag" => "div",
      "element_id" => "action_hint",
      "text" => CardI18n.plain_text("direct_reply_hint") |> metadata_text()
    }
  end

  defp meta_element(%{"meta" => meta}) when is_map(meta) do
    parts =
      []
      |> maybe_page_part(meta)
      |> maybe_meta_part(meta["source_count"], "#{meta["source_count"]} 个来源")
      |> maybe_meta_part(
        positive_value(meta["attachment_count"]),
        "已附上 #{meta["attachment_count"]} 个文件"
      )
      |> maybe_meta_part(meta["elapsed_ms"], elapsed_text(meta["elapsed_ms"]))

    case parts do
      [] ->
        nil

      parts ->
        compact_metadata("meta", %{"content" => Enum.join(parts, " · ")}, "info_outlined")
    end
  end

  defp meta_element(_presentation), do: nil

  defp panel(id, title, content, icon_token, expanded) when is_map(title) do
    %{
      "tag" => "collapsible_panel",
      "element_id" => id,
      "expanded" => expanded,
      "header" => %{
        "title" => muted_panel_title(title),
        "vertical_align" => "center",
        "padding" => "0px 0px 0px 0px",
        "icon" => standard_icon(icon_token),
        "icon_position" => "left"
      },
      "padding" => "4px 0px 0px 20px",
      "margin" => "0px 0px 0px 0px",
      "vertical_spacing" => "4px",
      "elements" => [
        %{
          "tag" => "markdown",
          "content" => content,
          "text_size" => "notation",
          "margin" => "0px 0px 0px 0px"
        }
      ]
    }
  end

  defp compact_metadata(id, copy, icon_token) do
    %{
      "tag" => "div",
      "element_id" => id,
      "text" =>
        copy
        |> Map.put("tag", "plain_text")
        |> metadata_text(),
      "icon" => standard_icon(icon_token),
      "margin" => "0px 0px 0px 0px"
    }
  end

  # Collapsible-panel titles only accept tag/content; text_size and text_color
  # are component-level fields and make Feishu reject the mutation. Markdown
  # color syntax keeps the title visually secondary without leaving the schema.
  defp muted_panel_title(%{"content" => content} = title) when is_binary(content) do
    muted = %{
      "tag" => "markdown",
      "content" => muted_text(content)
    }

    case title["i18n_content"] do
      i18n_content when is_map(i18n_content) ->
        Map.put(
          muted,
          "i18n_content",
          Map.new(i18n_content, fn {key, value} -> {key, muted_text(value)} end)
        )

      _missing ->
        muted
    end
  end

  defp muted_text(content), do: "<font color='grey'>#{content}</font>"

  defp metadata_text(text) do
    Map.merge(text, %{
      "text_size" => "notation",
      "text_align" => "left",
      "text_color" => "grey"
    })
  end

  defp standard_icon(token) do
    %{
      "tag" => "standard_icon",
      "token" => token,
      "color" => "grey",
      "size" => "14px 14px"
    }
  end

  defp state_icon(%{"state" => state}) when state in ["debouncing", "working"],
    do: "ai-common_colorful"

  defp state_icon(%{"state" => "scheduled"}), do: "time_outlined"
  defp state_icon(%{"state" => "failed"}), do: "sheet-iconsets-caution_filled"
  defp state_icon(_presentation), do: "info_outlined"

  defp separator_elements([], _primary), do: []

  defp separator_elements(_metadata, primary) do
    if visible_primary_elements?(primary) do
      [
        %{
          "tag" => "hr",
          "element_id" => @separator_id,
          "margin" => "0px 0px 0px 0px"
        }
      ]
    else
      []
    end
  end

  defp maybe_result_title(%{"title" => title}, index) when is_binary(title) and title != "" do
    %{
      "tag" => "markdown",
      "element_id" => "rtitle#{index}",
      "content" => "**#{escape_inline(title)}**"
    }
  end

  defp maybe_result_title(_result, _index), do: nil

  defp takeaway_element(%{"takeaway" => text}, index) when is_binary(text) and text != "" do
    %{"tag" => "markdown", "element_id" => "rtake#{index}", "content" => text}
  end

  defp takeaway_element(_result, _index), do: nil

  defp caption_element(%{"caption" => text}, index) when is_binary(text) and text != "" do
    %{"tag" => "markdown", "element_id" => "rcap#{index}", "content" => text}
  end

  defp caption_element(_result, _index), do: nil

  defp plan_window(items) do
    current_index = Enum.find_index(items, &(&1["status"] == "in_progress")) || 0
    start_index = max(current_index - 1, 0)
    Enum.slice(items, start_index, 4)
  end

  defp plan_marker("completed"), do: "✅"
  defp plan_marker("in_progress"), do: "▶️"
  defp plan_marker("cancelled"), do: "⏭️"
  defp plan_marker(_status), do: "○"

  defp activity_marker("completed"), do: "✅"
  defp activity_marker("failed"), do: "⚠️"
  defp activity_marker("running"), do: "⏳"
  defp activity_marker(_phase), do: "○"

  defp activity_label(%{"label" => "正在" <> label}), do: String.trim_leading(label)
  defp activity_label(%{"label" => label}) when is_binary(label), do: label
  defp activity_label(_activity), do: "处理请求"

  defp summary(presentation) do
    presentation
    |> ReplyPresentation.fallback_text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(80)
  end

  defp safe_stream_markdown(text) do
    fence_count = Regex.scan(~r/```/, text) |> length()
    if rem(fence_count, 2) == 1, do: text <> "\n```", else: text
  end

  defp validate_budget(card, mode) do
    if within_budget?(card), do: {:ok, card}, else: degrade_card(card, mode)
  end

  defp degrade_card(card, _mode) do
    optional_groups = [
      ["thought", "activity"],
      :typed_results,
      ["plan", "receipts"]
    ]

    Enum.reduce_while(optional_groups, card, fn group, candidate ->
      candidate = drop_optional_elements(candidate, group)

      if within_budget?(candidate),
        do: {:halt, {:ok, candidate}},
        else: {:cont, candidate}
    end)
    |> case do
      {:ok, _card} = result -> result
      _still_oversized -> {:error, :cardkit_soft_budget_exceeded}
    end
  end

  defp within_budget?(card) do
    byte_size(Ankole.JSON.encode!(card)) <= @soft_bytes and
      count_elements(card) <= @soft_elements
  end

  defp drop_optional_elements(card, group) do
    elements = get_in(card, ["body", "elements"])

    kept =
      Enum.reject(elements, fn element ->
        id = element["element_id"] || ""

        case group do
          :typed_results ->
            String.starts_with?(id, ["result", "rtitle", "rtake", "rcap"])

          ids when is_list(ids) ->
            id in ids
        end
      end)

    card
    |> put_in(["body", "elements"], kept)
    |> remove_orphan_separator()
  end

  defp remove_orphan_separator(card) do
    elements = get_in(card, ["body", "elements"])

    if Enum.any?(elements, &(&1["element_id"] in @metadata_element_ids)) and
         visible_primary_elements?(elements) do
      card
    else
      put_in(
        card,
        ["body", "elements"],
        Enum.reject(elements, &(&1["element_id"] == @separator_id))
      )
    end
  end

  defp visible_primary_elements?(elements) do
    Enum.any?(elements, fn
      %{"element_id" => "answer", "content" => content} ->
        present_text?(content)

      %{"element_id" => "actions"} ->
        true

      %{"element_id" => "trigger_context"} ->
        true

      %{"element_id" => "action_form" <> _suffix} ->
        true

      %{"element_id" => id} when is_binary(id) ->
        String.starts_with?(id, ["result", "rtitle", "rtake", "rcap"])

      _element ->
        false
    end)
  end

  defp count_elements(value) when is_list(value),
    do: Enum.reduce(value, 0, &(count_elements(&1) + &2))

  defp count_elements(value) when is_map(value) do
    own = if is_binary(value["tag"]), do: 1, else: 0
    own + Enum.reduce(Map.values(value), 0, &(count_elements(&1) + &2))
  end

  defp count_elements(_value), do: 0

  defp index_elements(elements) do
    Map.new(elements, fn element -> {element["element_id"], element} end)
  end

  defp previous_element_ids(previous_by_id, opts) do
    case Keyword.get(opts, :previous_element_ids) do
      ids when is_list(ids) ->
        case Enum.filter(ids, &is_binary/1) do
          [] -> previous_by_id |> Map.keys() |> MapSet.new()
          recorded_ids -> MapSet.new(recorded_ids)
        end

      _not_recorded ->
        previous_by_id |> Map.keys() |> MapSet.new()
    end
  end

  defp maybe_delete(actions, []), do: actions

  defp maybe_delete(actions, ids) do
    actions ++ [%{"action" => "delete_elements", "params" => %{"element_ids" => Enum.sort(ids)}}]
  end

  defp append_updates(actions, ids, previous, current) do
    ids
    |> Enum.sort()
    |> Enum.reduce(actions, fn id, acc ->
      if previous[id] == current[id] do
        acc
      else
        acc ++
          [
            %{
              "action" => "update_element",
              "params" => %{"element_id" => id, "element" => current[id]}
            }
          ]
      end
    end)
  end

  defp append_additions(actions, elements, added_ids) do
    elements
    |> addition_runs(added_ids)
    |> Enum.reduce(actions, fn {additions, type, target}, acc ->
      maybe_add_elements(acc, additions, type, target)
    end)
  end

  # A CardKit element can appear after its neighbours have already been
  # inserted. Anchor each new contiguous run to the next existing element (or
  # the previous one for a trailing run), so asynchronous plan/activity events
  # cannot permanently scramble the semantic renderer order.
  defp addition_runs(elements, added_ids) do
    {runs, pending, last_existing_id} =
      Enum.reduce(elements, {[], [], nil}, fn element, {runs, pending, last_existing_id} ->
        id = element["element_id"]

        if MapSet.member?(added_ids, id) do
          {runs, [element | pending], last_existing_id}
        else
          runs =
            case pending do
              [] -> runs
              pending -> runs ++ [{Enum.reverse(pending), "insert_before", id}]
            end

          {runs, [], id}
        end
      end)

    case pending do
      [] ->
        runs

      pending when is_binary(last_existing_id) ->
        runs ++ [{Enum.reverse(pending), "insert_after", last_existing_id}]
    end
  end

  defp maybe_add_elements(actions, [], _type, _target), do: actions

  defp maybe_add_elements(actions, elements, type, target) do
    actions ++
      [
        %{
          "action" => "add_elements",
          "params" => %{"type" => type, "target_element_id" => target, "elements" => elements}
        }
      ]
  end

  defp append(elements, nil), do: elements
  defp append(elements, element), do: elements ++ [element]
  defp append_all(elements, values), do: elements ++ values

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp result_id(index), do: "result#{index}"

  defp button_type("primary"), do: "primary_filled"
  defp button_type("danger"), do: "danger"
  defp button_type(_style), do: "default"

  defp maybe_meta_part(parts, nil, _text), do: parts
  defp maybe_meta_part(parts, _value, text), do: parts ++ [text]

  defp maybe_page_part(
         parts,
         %{"cardkit_page_index" => index, "cardkit_page_count" => count}
       )
       when is_integer(index) and is_integer(count) and count > 1 do
    suffix = if index == 0, do: "", else: "（续）"
    parts ++ ["第 #{index + 1} 张#{suffix}"]
  end

  defp maybe_page_part(parts, _meta), do: parts

  defp positive_value(value) when is_integer(value) and value > 0, do: value
  defp positive_value(_value), do: nil

  defp elapsed_text(milliseconds) when is_integer(milliseconds) and milliseconds >= 1_000,
    do: "#{Float.round(milliseconds / 1_000, 1)} 秒"

  defp elapsed_text(_milliseconds), do: nil

  defp escape_inline(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  defp escape_markdown_text(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> then(fn text ->
      Enum.reduce(["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "!", "|"], text, fn
        marker, escaped -> String.replace(escaped, marker, "\\#{marker}")
      end)
    end)
  end

  defp escape_link_destination(value) do
    value
    |> to_string()
    |> String.replace("(", "&#40;")
    |> String.replace(")", "&#41;")
  end

  defp truncate(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      String.slice(text, 0, max_chars - 1) <> "…"
    end
  end

  defp first_cardkit_page?(presentation) do
    get_in(presentation, ["meta", "cardkit_page_index"]) in [nil, 0]
  end

  defp scope_to_page(presentation, opts) do
    case Keyword.fetch(opts, :answer) do
      :error ->
        presentation

      {:ok, answer} when is_binary(answer) ->
        index = Keyword.get(opts, :page_index, 0)
        count = Keyword.get(opts, :page_count, 1)
        tail? = Keyword.get(opts, :page_tail, true)

        presentation
        |> Map.put("answer", answer)
        |> Map.put("__cardkit_page_tail", tail?)
        |> Map.update!("meta", fn meta ->
          meta
          |> Map.put("cardkit_page_index", index)
          |> Map.put("cardkit_page_count", count)
        end)
        |> then(fn presentation ->
          if tail? do
            presentation
          else
            presentation
            |> Map.delete("plan")
            |> Map.delete("thought")
            |> Map.put("activities", %{})
            |> Map.put("results", [])
            |> Map.put("receipts", [])
            |> Map.put("actions", [])
          end
        end)

      {:ok, _invalid} ->
        presentation
    end
  end
end
