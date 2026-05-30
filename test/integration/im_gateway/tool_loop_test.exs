defmodule BullX.Integration.IMGateway.ToolLoopTest do
  @moduledoc """
  Family I — model/tool loop behavior through the IM gateway pipeline.

  The mock LLM is allowed to return a tool-call turn before the visible answer.
  The integration invariant is that the intermediate tool result is persisted,
  the model is called again with that result in context, and only the final
  assistant text is delivered back to IM.
  """
  use BullX.Integration.IMGateway.Case

  test "I1: a tool-call turn persists tool results before the final visible reply" do
    MockLLM.push_tool_calls([
      %{
        "id" => "call_unknown_1",
        "name" => "unknown_tool",
        "arguments" => %{"value" => "from model"}
      }
    ])

    MockLLM.push_text("final answer after tool result")

    chat = new_dm(with: :alice)
    say(chat, :alice, "use a tool then answer")
    settle()

    assert MockLLM.call_count() == 2
    assert [%{op: "send", text: "final answer after tool result"}] = transcript(chat)

    assert %Message{role: :tool, content: [%{"tool_call_id" => "call_unknown_1"} = result]} =
             Repo.one!(from(m in Message, where: m.role == :tool))

    assert result["is_error"] == true
    assert get_in(result, ["error", "code"]) == "tool_unknown"

    [first, second] = Enum.map(MockLLM.requests(), &MockLLM.prompt_text/1)
    assert first =~ "use a tool then answer"
    assert second =~ "tool_unknown"
  end
end
