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
    assert state["i18n_content"]["zh_cn"] == "正在完善回答…"
    assert state["i18n_content"]["en_us"] == "Refining the answer…"

    answer = Enum.find(elements, &(&1["element_id"] == "answer"))
    assert answer["tag"] == "markdown"
    assert answer["content"] == presentation["answer"]

    assert Enum.any?(elements, &(&1["element_id"] == "plan"))
    assert Enum.any?(elements, &(&1["element_id"] == "thought"))
    assert Enum.any?(elements, &(&1["tag"] == "table"))

    receipts = Enum.find(elements, &(&1["element_id"] == "receipts"))
    receipts_text = get_in(receipts, ["elements", Access.at(0), "content"])
    assert receipts_text =~ "已更正项目偏好"
    assert receipts_text =~ "已安排后续检查"

    plan = Enum.find(elements, &(&1["element_id"] == "plan"))
    assert get_in(plan, ["header", "title", "i18n_content", "en_us"]) == "Execution plan · 1/2"
  end

  test "terminal rendering removes leased thought and closes streaming without changing final Markdown" do
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
    assert Enum.find(elements, &(&1["element_id"] == "answer"))["content"] == live["answer"]
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

    assert button["value"] == %{
             "version" => "ankole.interactive_output.action.v1",
             "interactionId" => "clarify:4",
             "interactionVersion" => 4,
             "controlId" => "audience",
             "selectedOptionId" => "operators",
             "optionValue" => "Operators",
             "sourceActorEventId" => source_event_id
           }
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
    assert first_state["i18n_content"]["zh_cn"] == "回答继续于下一张卡片"
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
    assert Enum.find(tail_elements, &(&1["element_id"] == "meta"))["content"] =~ "第 2 张"
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
end
