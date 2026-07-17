defmodule Ankole.Plugins.LarkAdapter.CardKitRendererTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.LarkAdapter.CardKit.Renderer
  alias Ankole.SignalsGateway.ReplyPresentation

  test "renders live Markdown, plan, thought, typed results, receipts and actions as CardKit 2.0" do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("## 标题\n\n- [链接](https://example.com)\n- `code`")
      |> ReplyPresentation.apply_event("reasoning.delta", %{
        "operation_id" => "reasoning",
        "revision" => 1,
        "text" => "这是过程中的原始思考"
      })
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 2,
        "items" => [
          %{"id" => "1", "content" => "分析", "status" => "completed"},
          %{"id" => "2", "content" => "生成", "status" => "in_progress"}
        ]
      })
      |> ReplyPresentation.apply_event("result.table", %{
        "operation_id" => "table",
        "revision" => 3,
        "title" => "数据",
        "columns" => [%{"key" => "x", "label" => "X"}],
        "rows" => [%{"x" => 1}]
      })
      |> ReplyPresentation.apply_event("memory.lookup", %{
        "operation_id" => "memory",
        "revision" => 4,
        "phase" => "completed",
        "label" => "回忆相关上下文",
        "source_count" => 2
      })
      |> ReplyPresentation.apply_event("memory.mutation_receipt", %{
        "operation_id" => "memory-write",
        "revision" => 5,
        "phase" => "confirmed",
        "summary" => "已更正项目偏好",
        "scope" => "Brain 记忆"
      })
      |> ReplyPresentation.apply_event("effect.receipt", %{
        "operation_id" => "checkback",
        "revision" => 6,
        "phase" => "confirmed",
        "summary" => "已安排后续检查",
        "scope" => "明天 09:00"
      })

    assert {:ok, card} = Renderer.render(presentation, mode: :working)
    assert card["schema"] == "2.0"
    assert card["config"]["update_multi"]
    assert card["config"]["streaming_mode"]

    elements = get_in(card, ["body", "elements"])
    state = Enum.find(elements, &(&1["element_id"] == "state"))
    assert get_in(state, ["text", "i18n_content", "zh_cn"]) == "正在完善回答…"
    assert get_in(state, ["text", "i18n_content", "en_us"]) == "Refining the answer…"
    assert state["text"]["text_size"] == "notation"
    assert state["text"]["text_color"] == "grey"
    assert state["icon"]["token"] == "ai-common_colorful"

    answer = Enum.find(elements, &(&1["element_id"] == "answer"))
    assert answer["tag"] == "markdown"
    assert answer["content"] == presentation["answer"]

    separator = Enum.find(elements, &(&1["element_id"] == "separator"))
    assert separator["tag"] == "hr"

    assert element_index(elements, "state") < element_index(elements, "receipts")
    assert element_index(elements, "receipts") < element_index(elements, "plan")
    assert element_index(elements, "plan") < element_index(elements, "thought")
    assert element_index(elements, "thought") < element_index(elements, "separator")
    assert element_index(elements, "separator") < element_index(elements, "answer")
    assert Enum.any?(elements, &(&1["tag"] == "table"))

    receipts = Enum.find(elements, &(&1["element_id"] == "receipts"))
    receipts_text = get_in(receipts, ["elements", Access.at(0), "content"])
    assert receipts_text =~ "已更正项目偏好"
    assert receipts_text =~ "已安排后续检查"
    refute receipts["expanded"]
    assert get_in(receipts, ["header", "icon", "token"]) == "check_outlined"
    assert get_in(receipts, ["header", "icon_position"]) == "left"

    assert get_in(receipts, ["header", "title", "tag"]) == "markdown"

    assert get_in(receipts, ["header", "title", "content"]) ==
             "<font color='grey'>Confirmed changes</font>"

    assert get_in(receipts, ["header", "title", "i18n_content", "zh_cn"]) ==
             "<font color='grey'>已确认的变更</font>"

    refute Map.has_key?(get_in(receipts, ["header", "title"]), "text_size")
    refute Map.has_key?(get_in(receipts, ["header", "title"]), "text_color")
    assert get_in(receipts, ["elements", Access.at(0), "text_size"]) == "notation"
    refute Map.has_key?(get_in(receipts, ["elements", Access.at(0)]), "text_color")
    refute Map.has_key?(get_in(receipts, ["elements", Access.at(0)]), "font_color")

    plan = Enum.find(elements, &(&1["element_id"] == "plan"))

    assert get_in(plan, ["header", "title", "i18n_content", "en_us"]) ==
             "<font color='grey'>Execution plan · 1/2</font>"

    assert get_in(plan, ["header", "icon", "token"]) == "list-check_outlined"
    assert plan["expanded"]

    activity = Enum.find(elements, &(&1["element_id"] == "activity"))
    refute activity["expanded"]

    thought = Enum.find(elements, &(&1["element_id"] == "thought"))
    assert get_in(thought, ["header", "icon", "token"]) == "ai-common_colorful"
    assert thought["expanded"]
  end

  test "a completed answer without metadata has no status or divider" do
    live =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer("```elixir\nIO.puts(\"ok\")\n```")
      |> ReplyPresentation.apply_event("reasoning.delta", %{
        "operation_id" => "r",
        "revision" => 1,
        "text" => "不能进入终态"
      })

    terminal = ReplyPresentation.terminal(live, "completed", live["answer"])

    assert {:ok, card} = Renderer.render(terminal, mode: :terminal)
    refute card["config"]["streaming_mode"]
    assert card["config"]["summary"]["content"] =~ "IO.puts"

    elements = get_in(card, ["body", "elements"])
    refute Enum.any?(elements, &(&1["element_id"] == "thought"))
    refute Enum.any?(elements, &(&1["element_id"] == "state"))
    refute Enum.any?(elements, &(&1["element_id"] == "separator"))
    assert Enum.find(elements, &(&1["element_id"] == "answer"))["content"] == live["answer"]
  end

  test "renders failed BackgroundAgentJob context as a quoted prefix only on the first card" do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.project_trigger("background_agent_job.failed", %{
        "data" => %{
          "title" => "第二版 deep research",
          "result_summary" => "返回 JSON Schema 少声明了必填字段"
        }
      })
      |> ReplyPresentation.append_answer("我已修正配置并重新提交任务。")

    assert {:ok, first_card} =
             Renderer.render(presentation,
               mode: :working,
               answer: presentation["answer"],
               page_index: 0,
               page_count: 2,
               page_tail: false
             )

    first_elements = get_in(first_card, ["body", "elements"])
    trigger = Enum.find(first_elements, &(&1["element_id"] == "trigger_context"))

    assert trigger["tag"] == "markdown"

    assert trigger["i18n_content"] == %{
             "en_us" =>
               "> Background Agent Job “第二版 deep research” failed: 返回 JSON Schema 少声明了必填字段",
             "zh_cn" => "> 后台 Agent 任务「第二版 deep research」失败：返回 JSON Schema 少声明了必填字段"
           }

    assert element_index(first_elements, "trigger_context") <
             element_index(first_elements, "answer")

    assert {:ok, second_card} =
             Renderer.render(presentation,
               mode: :working,
               answer: "后续分页",
               page_index: 1,
               page_count: 2,
               page_tail: true
             )

    refute Enum.any?(
             get_in(second_card, ["body", "elements"]),
             &(&1["element_id"] == "trigger_context")
           )
  end

  test "completed metadata is collapsed above a divider and the final answer" do
    terminal =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("memory.mutation_receipt", %{
        "operation_id" => "memory-write",
        "revision" => 1,
        "phase" => "confirmed",
        "summary" => "已创建记忆条目",
        "scope" => "Brain 记忆"
      })
      |> ReplyPresentation.terminal("completed", "这是最终正文。")

    assert {:ok, card} = Renderer.render(terminal, mode: :terminal)
    elements = get_in(card, ["body", "elements"])

    assert Enum.map(elements, & &1["element_id"]) == ["receipts", "separator", "answer"]
    receipts = Enum.at(elements, 0)
    refute receipts["expanded"]
    assert get_in(receipts, ["header", "icon", "token"]) == "check_outlined"
    assert get_in(receipts, ["elements", Access.at(0), "content"]) =~ "已创建记忆条目"
    assert Enum.at(elements, 1)["tag"] == "hr"
    assert Enum.at(elements, 2)["content"] == "这是最终正文。"
  end

  test "a stopped reply without partial text renders metadata without a body or divider" do
    stopped =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 1,
        "items" => [
          %{"id" => "research", "content" => "研究请求", "status" => "in_progress"}
        ]
      })
      |> ReplyPresentation.terminal("stopped", "")
      |> Map.put("answer", "")

    assert {:ok, card} = Renderer.render(stopped, mode: :terminal)
    elements = get_in(card, ["body", "elements"])

    assert Enum.map(elements, & &1["element_id"]) == ["state", "plan"]
    refute Enum.any?(elements, &(&1["element_id"] == "answer"))
    refute Enum.any?(elements, &(&1["element_id"] == "separator"))
  end

  test "todo is expanded while work is running and collapsed after completion" do
    working =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 1,
        "items" => [
          %{"id" => "inspect", "content" => "检查卡片", "status" => "completed"},
          %{"id" => "finish", "content" => "完成验证", "status" => "in_progress"}
        ]
      })

    assert {:ok, working_card} = Renderer.render(working, mode: :working)

    working_plan =
      Enum.find(get_in(working_card, ["body", "elements"]), &(&1["element_id"] == "plan"))

    assert working_plan["expanded"]

    terminal =
      working
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 2,
        "items" => [
          %{"id" => "inspect", "content" => "检查卡片", "status" => "completed"},
          %{"id" => "finish", "content" => "完成验证", "status" => "completed"}
        ]
      })
      |> ReplyPresentation.terminal("completed", "验证完成。")

    assert {:ok, terminal_card} = Renderer.render(terminal, mode: :terminal)
    terminal_elements = get_in(terminal_card, ["body", "elements"])
    terminal_plan = Enum.find(terminal_elements, &(&1["element_id"] == "plan"))

    refute terminal_plan["expanded"]

    assert element_index(terminal_elements, "plan") <
             element_index(terminal_elements, "separator")

    assert element_index(terminal_elements, "separator") <
             element_index(terminal_elements, "answer")
  end

  test "plan owns working focus while collapsed activity names current work" do
    with_plan =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 1,
        "items" => [
          %{"id" => "inspect", "content" => "检查实现", "status" => "in_progress"},
          %{"id" => "verify", "content" => "完成验证", "status" => "pending"}
        ]
      })
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "read",
        "revision" => 2,
        "phase" => "running",
        "label" => "读取文件：core/agent-loop.ts"
      })
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "test",
        "revision" => 3,
        "phase" => "running",
        "label" => "运行测试 · mix test"
      })

    assert {:ok, card} = Renderer.render(with_plan, mode: :working)
    elements = get_in(card, ["body", "elements"])
    plan = Enum.find(elements, &(&1["element_id"] == "plan"))
    activity = Enum.find(elements, &(&1["element_id"] == "activity"))

    assert plan["expanded"]
    refute activity["expanded"]

    assert get_in(activity, ["header", "title", "i18n_content", "zh_cn"]) ==
             "<font color='grey'>处理过程 · 运行测试 · mix test 等 2 项</font>"

    assert get_in(activity, ["header", "title", "i18n_content", "en_us"]) ==
             "<font color='grey'>Progress · 运行测试 · mix test among 2 items</font>"

    without_plan =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "read",
        "revision" => 1,
        "phase" => "running",
        "label" => "读取文件：core/agent-loop.ts"
      })

    assert {:ok, card} = Renderer.render(without_plan, mode: :working)
    activity = Enum.find(get_in(card, ["body", "elements"]), &(&1["element_id"] == "activity"))

    assert activity["expanded"]

    assert get_in(activity, ["header", "title", "i18n_content", "zh_cn"]) ==
             "<font color='grey'>处理过程 · 读取文件：core/agent-loop.ts</font>"

    long_label = String.duplicate("长", 80)

    long_activity =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "long",
        "revision" => 1,
        "phase" => "running",
        "label" => long_label
      })

    assert {:ok, card} = Renderer.render(long_activity, mode: :working)
    activity = Enum.find(get_in(card, ["body", "elements"]), &(&1["element_id"] == "activity"))

    assert get_in(activity, ["header", "title", "i18n_content", "zh_cn"]) ==
             "<font color='grey'>处理过程 · #{String.duplicate("长", 59)}…</font>"
  end

  test "working status uses the AI icon and adds a divider only after body content appears" do
    empty = ReplyPresentation.new()

    assert {:ok, empty_card} = Renderer.render(empty, mode: :working)
    empty_elements = get_in(empty_card, ["body", "elements"])
    state = Enum.find(empty_elements, &(&1["element_id"] == "state"))

    assert state["tag"] == "div"
    assert state["icon"]["token"] == "ai-common_colorful"
    refute Enum.any?(empty_elements, &(&1["element_id"] == "separator"))

    assert {:ok, answering_card} =
             empty
             |> ReplyPresentation.append_answer("正文开始")
             |> Renderer.render(mode: :working)

    answering_elements = get_in(answering_card, ["body", "elements"])

    assert element_index(answering_elements, "state") <
             element_index(answering_elements, "separator")

    assert element_index(answering_elements, "separator") <
             element_index(answering_elements, "answer")

    answering = ReplyPresentation.append_answer(empty, "正文开始")
    assert {:ok, actions} = Renderer.batch_actions(empty, answering, mode: :working)

    separator_addition =
      Enum.find(actions, fn action ->
        action["action"] == "add_elements" and
          Enum.any?(get_in(action, ["params", "elements"]), &(&1["element_id"] == "separator"))
      end)

    assert get_in(separator_addition, ["params", "type"]) == "insert_before"
    assert get_in(separator_addition, ["params", "target_element_id"]) == "answer"
  end

  test "builds one batch mutation from semantic element differences" do
    previous = ReplyPresentation.new() |> ReplyPresentation.append_answer("draft")

    current =
      previous
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "search",
        "revision" => 1,
        "phase" => "running",
        "label" => "检索资料"
      })

    assert {:ok, actions} = Renderer.batch_actions(previous, current, mode: :working)
    assert Enum.any?(actions, &(&1["action"] in ["add_elements", "update_element"]))
    refute Enum.any?(actions, &get_in(&1, ["params", "partial_element", "raw_tool_name"]))

    activity_addition =
      Enum.find(actions, fn action ->
        action["action"] == "add_elements" and
          Enum.any?(get_in(action, ["params", "elements"]), &(&1["element_id"] == "activity"))
      end)

    assert get_in(activity_addition, ["params", "target_element_id"]) == "separator"
  end

  test "late metadata additions keep the renderer's semantic order" do
    previous =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "command",
        "revision" => 1,
        "phase" => "running",
        "label" => "操作工作环境"
      })

    current =
      previous
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 2,
        "items" => [
          %{"id" => "inspect", "content" => "检查卡片", "status" => "in_progress"}
        ]
      })

    assert {:ok, actions} = Renderer.batch_actions(previous, current, mode: :working)

    plan_addition =
      Enum.find(actions, fn action ->
        action["action"] == "add_elements" and
          Enum.any?(get_in(action, ["params", "elements"]), &(&1["element_id"] == "plan"))
      end)

    assert get_in(plan_addition, ["params", "type"]) == "insert_before"
    assert get_in(plan_addition, ["params", "target_element_id"]) == "activity"

    activity_update =
      Enum.find(actions, fn action ->
        action["action"] == "update_element" and
          get_in(action, ["params", "element_id"]) == "activity"
      end)

    assert is_map(activity_update)
    refute get_in(activity_update, ["params", "element", "expanded"])
  end

  test "renders versioned choice values and locks an accepted choice in place" do
    source_event_id = Ecto.UUID.generate()

    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 4,
        "prompt" => "请选择受众",
        "controls" => [
          %{
            "id" => "operators",
            "type" => "button",
            "label" => "运营人员",
            "interaction_id" => "clarify:4",
            "source_actor_event_id" => source_event_id,
            "control_id" => "audience",
            "selected_option_id" => "operators",
            "option_value" => "Operators",
            "revision" => 4,
            "disabled" => true,
            "selected" => true
          },
          %{
            "id" => "executives",
            "type" => "button",
            "label" => "管理层",
            "interaction_id" => "clarify:4",
            "source_actor_event_id" => source_event_id,
            "control_id" => "audience",
            "selected_option_id" => "executives",
            "option_value" => "Executives",
            "revision" => 4
          }
        ]
      })

    assert {:ok, card} = Renderer.render(presentation, mode: :terminal)
    actions = Enum.find(get_in(card, ["body", "elements"]), &(&1["element_id"] == "actions"))
    button = get_in(actions, ["columns", Access.at(0), "elements", Access.at(0)])

    button_names =
      Enum.map(actions["columns"], &get_in(&1, ["elements", Access.at(0), "name"]))

    assert button["disabled"]
    assert button_names == ["operators", "executives"]
    assert length(button_names) == length(Enum.uniq(button_names))
    assert button["text"]["content"] == "运营人员（已选择）"

    assert get_in(button, ["behaviors", Access.at(0)]) == %{
             "type" => "callback",
             "value" => %{
               "version" => "ankole.interactive_output.action.v1",
               "answerKind" => "choice",
               "interactionId" => "clarify:4",
               "interactionVersion" => 4,
               "controlId" => "audience",
               "selectedOptionId" => "operators",
               "optionValue" => "Operators",
               "sourceActorEventId" => source_event_id
             }
           }
  end

  test "renders a root-level free-text form and removes it after supersession" do
    source_event_id = Ecto.UUID.generate()

    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => "请补充范围",
        "controls" => [
          %{
            "id" => "all",
            "type" => "button",
            "label" => "全部",
            "interaction_id" => "clarify:form",
            "source_actor_event_id" => source_event_id,
            "control_id" => "scope",
            "selected_option_id" => "all",
            "option_value" => "All",
            "revision" => 1
          },
          %{
            "id" => "clarify-free-input",
            "type" => "form",
            "label" => "Reply",
            "style" => "primary",
            "interaction_id" => "clarify:form",
            "source_actor_event_id" => source_event_id,
            "control_id" => "clarify-free-input",
            "revision" => 1,
            "fields" => [
              %{
                "id" => "clarify-answer",
                "type" => "input",
                "label" => "Your answer",
                "required" => true,
                "multiline" => true,
                "max_length" => 1_000
              }
            ]
          }
        ]
      })

    assert {:ok, card} = Renderer.render(presentation, mode: :terminal)

    form =
      Enum.find(get_in(card, ["body", "elements"]), fn element ->
        String.starts_with?(element["element_id"] || "", "action_form")
      end)

    assert form["tag"] == "form"
    assert [input, submit] = form["elements"]
    assert input["tag"] == "input"
    assert input["name"] == "clarify-answer"
    assert input["input_type"] == "multiline_text"
    assert input["max_length"] == 1_000
    assert submit["form_action_type"] == "submit"

    assert get_in(submit, ["behaviors", Access.at(0)]) == %{
             "type" => "callback",
             "value" => %{
               "version" => "ankole.interactive_output.action.v1",
               "answerKind" => "free_text",
               "interactionId" => "clarify:form",
               "interactionVersion" => 1,
               "controlId" => "clarify-free-input",
               "inputName" => "clarify-answer",
               "sourceActorEventId" => source_event_id
             }
           }

    superseded = ReplyPresentation.resolve_interaction(presentation, "superseded")
    assert {:ok, card} = Renderer.render(superseded, mode: :terminal)

    refute Enum.any?(get_in(card, ["body", "elements"]), fn element ->
             String.starts_with?(element["element_id"] || "", "action_form")
           end)

    actions = Enum.find(get_in(card, ["body", "elements"]), &(&1["element_id"] == "actions"))
    assert Enum.all?(actions["columns"], &get_in(&1, ["elements", Access.at(0), "disabled"]))

    state = Enum.find(get_in(card, ["body", "elements"]), &(&1["element_id"] == "state"))
    assert state["text"]["content"] == "No longer active because the conversation continued"
    assert state["text"]["i18n_content"]["zh_cn"] == "已失效，对话已继续"
  end

  test "does not expose a button without a complete durable interaction locator" do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => "请选择",
        "controls" => [%{"id" => "unsafe", "type" => "button", "label" => "无实际命令"}]
      })

    assert {:ok, card} = Renderer.render(presentation, mode: :terminal)

    refute Enum.any?(
             get_in(card, ["body", "elements"]),
             &(&1["element_id"] == "actions")
           )
  end

  test "escapes parentheses in artifact link destinations without rewriting the URL" do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("artifact.available", %{
        "operation_id" => "artifact",
        "revision" => 1,
        "name" => "report.pdf",
        "description" => "打开报告",
        "url" => "https://example.com/reports/(draft)/report).pdf"
      })

    assert {:ok, card} = Renderer.render(presentation, mode: :working)

    artifact =
      Enum.find(
        get_in(card, ["body", "elements"]),
        &String.starts_with?(&1["element_id"], "result")
      )

    assert artifact["content"] ==
             "**report.pdf**\n\n[打开报告](https://example.com/reports/&#40;draft&#41;/report&#41;.pdf)"
  end

  test "a sealed page shows only stable content while the tail keeps terminal UX" do
    terminal =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("result.metrics", %{
        "operation_id" => "metrics",
        "revision" => 1,
        "title" => "摘要",
        "metrics" => [%{"label" => "来源", "value" => "12"}]
      })
      |> ReplyPresentation.terminal("completed", "第一页\n第二页")

    assert {:ok, first} =
             Renderer.render(terminal,
               mode: :terminal,
               answer: "第一页\n",
               page_index: 0,
               page_count: 2,
               page_tail: false
             )

    first_elements = get_in(first, ["body", "elements"])
    first_state = Enum.find(first_elements, &(&1["element_id"] == "state"))
    assert get_in(first_state, ["text", "i18n_content", "zh_cn"]) == "回答继续于下一张卡片"
    assert element_index(first_elements, "state") < element_index(first_elements, "separator")
    assert element_index(first_elements, "separator") < element_index(first_elements, "answer")
    refute Enum.any?(first_elements, &String.starts_with?(&1["element_id"], "result"))
    refute first["config"]["streaming_mode"]

    assert {:ok, tail} =
             Renderer.render(terminal,
               mode: :terminal,
               answer: "第二页",
               page_index: 1,
               page_count: 2,
               page_tail: true
             )

    tail_elements = get_in(tail, ["body", "elements"])
    assert Enum.any?(tail_elements, &String.starts_with?(&1["element_id"], "result"))

    assert get_in(
             Enum.find(tail_elements, &(&1["element_id"] == "meta")),
             ["text", "content"]
           ) =~ "第 2 张"

    assert element_index(tail_elements, "meta") < element_index(tail_elements, "separator")
    assert element_index(tail_elements, "separator") < element_index(tail_elements, "answer")
  end

  test "oversized typed detail degrades before the terminal answer" do
    columns = for index <- 1..8, do: %{"key" => "c#{index}", "label" => "列 #{index}"}

    rows =
      for row <- 1..20 do
        Map.new(columns, fn column ->
          {column["key"], String.duplicate("数据#{row}", 80)}
        end)
      end

    terminal =
      Enum.reduce(1..12, ReplyPresentation.new(), fn index, presentation ->
        ReplyPresentation.apply_event(presentation, "result.table", %{
          "operation_id" => "table-#{index}",
          "revision" => index,
          "title" => "表格 #{index}",
          "columns" => columns,
          "rows" => rows
        })
      end)
      |> ReplyPresentation.terminal("completed", "必须保留的最终结论")

    assert {:ok, card} = Renderer.render(terminal, mode: :terminal)
    elements = get_in(card, ["body", "elements"])
    assert Enum.find(elements, &(&1["element_id"] == "answer"))["content"] == "必须保留的最终结论"
    refute Enum.any?(elements, &(&1["tag"] == "table"))
  end

  defp element_index(elements, id) do
    Enum.find_index(elements, &(&1["element_id"] == id))
  end
end
