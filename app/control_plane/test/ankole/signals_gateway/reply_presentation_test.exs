defmodule Ankole.SignalsGateway.ReplyPresentationTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ReplyPresentation

  test "merges live answer and reasoning while excluding reasoning from recovery and terminal truth" do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("reasoning.delta", %{
        "operation_id" => "reasoning-1",
        "revision" => 1,
        "text" => "先检查来源"
      })
      |> ReplyPresentation.append_answer("## 结论\n\n")
      |> ReplyPresentation.append_answer("保留 **Markdown**。")

    assert presentation["thought"] == "先检查来源"
    assert presentation["answer"] == "## 结论\n\n保留 **Markdown**。"

    checkpoint = ReplyPresentation.checkpoint(presentation)
    refute Map.has_key?(checkpoint, "thought")

    terminal = ReplyPresentation.terminal(presentation, "completed", presentation["answer"])
    refute Map.has_key?(terminal, "thought")
    assert terminal["state"] == "completed"
    assert terminal["answer"] == presentation["answer"]
  end

  test "preserves an answer larger than the old single-message ceiling without truncation" do
    answer =
      "# Long answer\n\n" <>
        String.duplicate("Ankole 保留完整 Markdown 内容。\n\n", 8_000)

    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.append_answer(answer)

    assert byte_size(presentation["answer"]) > 120_000
    assert presentation["answer"] == answer
    assert ReplyPresentation.checkpoint(presentation)["answer"] == answer

    terminal = ReplyPresentation.terminal(presentation, "completed", answer)
    assert terminal["answer"] == answer
  end

  test "revisioned plan snapshots replace older state instead of appending logs" do
    first =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 2,
        "items" => [
          %{"id" => "a", "content" => "调研", "status" => "completed"},
          %{"id" => "b", "content" => "实现", "status" => "in_progress"}
        ]
      })

    stale =
      ReplyPresentation.apply_event(first, "plan.snapshot", %{
        "operation_id" => "todo",
        "revision" => 1,
        "items" => [%{"id" => "old", "content" => "过期", "status" => "pending"}]
      })

    assert stale == first
    assert get_in(first, ["plan", "revision"]) == 2
    assert Enum.map(first["plan"]["items"], & &1["id"]) == ["a", "b"]
  end

  test "semantic tool activity and confirmed receipts retain safe projections only" do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("tool.activity", %{
        "operation_id" => "call-1",
        "revision" => 1,
        "phase" => "running",
        "label" => "检索资料",
        "arguments" => %{"token" => "must-not-survive"},
        "raw_tool_name" => "internal_secret_tool"
      })
      |> ReplyPresentation.apply_event("memory.mutation_receipt", %{
        "operation_id" => "call-2",
        "revision" => 2,
        "phase" => "confirmed",
        "summary" => "已更新项目偏好",
        "scope" => "当前用户"
      })

    assert get_in(presentation, ["activities", "call-1", "label"]) == "检索资料"
    refute get_in(presentation, ["activities", "call-1"]) |> Map.has_key?("arguments")
    refute get_in(presentation, ["activities", "call-1"]) |> Map.has_key?("raw_tool_name")

    assert [%{"summary" => "已更新项目偏好", "scope" => "当前用户"}] =
             presentation["receipts"]
  end

  test "accepts bounded typed result and interaction projections without provider JSON" do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("result.table", %{
        "operation_id" => "table-1",
        "revision" => 1,
        "title" => "比较",
        "columns" => [
          %{"key" => "name", "label" => "名称"},
          %{"key" => "value", "label" => "数值"}
        ],
        "rows" => [%{"name" => "A", "value" => 42}],
        "card_json" => %{"tag" => "button"}
      })
      |> ReplyPresentation.apply_event("interaction.request", %{
        "operation_id" => "question-1",
        "revision" => 2,
        "prompt" => "请选择范围",
        "controls" => [
          %{"id" => "all", "type" => "button", "label" => "全部", "command" => "choose"}
        ]
      })

    assert presentation["state"] == "awaiting_input"
    refute Map.has_key?(presentation, "thought")
    assert [%{"kind" => "table"} = table] = presentation["results"]
    refute Map.has_key?(table, "card_json")
    assert [%{"type" => "button", "label" => "全部"}] = presentation["actions"]
  end

  test "normalization preserves explicit false values from string and atom keys" do
    presentation =
      ReplyPresentation.normalize(%{
        "actions" => [
          %{
            "id" => "string-keys",
            "type" => "button",
            "label" => "String keys",
            "disabled" => false,
            "selected" => false
          },
          %{
            id: "atom-keys",
            type: "button",
            label: "Atom keys",
            disabled: false,
            selected: false
          }
        ]
      })

    assert Enum.map(presentation["actions"], &Map.take(&1, ["id", "disabled", "selected"])) == [
             %{"id" => "string-keys", "disabled" => false, "selected" => false},
             %{"id" => "atom-keys", "disabled" => false, "selected" => false}
           ]
  end
end
