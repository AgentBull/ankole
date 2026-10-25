defmodule Ankole.Pod.Chat.ActivityTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.Activity

  test "completed tools survive removal from the pending execution queue in start order" do
    data = %{
      activity_conversation_id: nil,
      activity_revision: 0,
      turn: %{pending: %{}},
      activity_tools: []
    }

    data = activity(data, "second-sorted-id", "running")
    data = activity(data, "first-sorted-id", "running")
    data = activity(data, "second-sorted-id", "completed")
    data = activity(data, "first-sorted-id", "failed")
    data = activity(data, "second-sorted-id", "running")

    assert [{"second-sorted-id", completed, _}, {"first-sorted-id", failed, _}] =
             data.activity_tools

    assert completed["phase"] == "completed"
    assert failed["phase"] == "failed"
    assert is_integer(completed["duration_ms"])
    assert data.turn.pending == %{}
  end

  test "the committed result corrects optional Worker progress without losing its label" do
    data = %{
      activity_conversation_id: nil,
      activity_revision: 0,
      turn: %{pending: %{}},
      activity_tools: []
    }

    data = activity(data, "read", "running") |> activity("read", "completed")

    data =
      Activity.complete_tool(data, "read", %Ankole.Sessions.ToolResult{
        is_error: true,
        duration_ms: 42
      })

    data = activity(data, "read", "running")

    assert [{"read", %{"phase" => "failed", "duration_ms" => 42, "label" => "Read page"}, _}] =
             data.activity_tools
  end

  test "a long turn keeps every completed step" do
    data = %{
      activity_conversation_id: nil,
      activity_revision: 0,
      turn: %{pending: %{}},
      activity_tools: []
    }

    data =
      Enum.reduce(1..40, data, fn id, current -> activity(current, to_string(id), "completed") end)

    assert Enum.map(data.activity_tools, &elem(&1, 0)) == Enum.map(1..40, &to_string/1)
  end

  defp activity(data, id, phase),
    do:
      Activity.present(data, %{
        "kind" => "tool.activity",
        "payload" => %{"operation_id" => id, "phase" => phase, "label" => "Read page"}
      })
end
