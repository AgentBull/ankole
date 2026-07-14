defmodule Ankole.SignalsGateway.ClarifyPromptTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.LarkAdapter.Card
  alias Ankole.SignalsGateway.ClarifyPrompt

  test "extracts wrapped clarify output into text fallback and portable card choices" do
    output =
      %{
        "tool" => "clarify",
        "ok" => true,
        "question" => "Who should this brief target?",
        "choices" => [
          %{"label" => "Operators", "description" => "People running the system."},
          %{"label" => "Executives"}
        ]
      }
      |> Ankole.JSON.encode!()
      |> untrusted_tool_output()

    assert {:ok, prompt} =
             ClarifyPrompt.from_response_items([
               %{
                 "type" => "function_call",
                 "call_id" => "call-clarify-1",
                 "name" => "clarify",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call-clarify-1",
                 "output" => output
               }
             ])

    assert prompt["fallback_visible_text"] ==
             """
             Who should this brief target?

             1. Operators — People running the system.
             2. Executives

             Reply with a number or type your answer.
             """
             |> String.trim_trailing()

    interactive = prompt["interactive_output"]

    assert Enum.map(interactive["choices"], & &1["label"]) ==
             ["Operators", "Executives"]

    assert interactive["free_input"]

    assert {:ok, card} = Card.render(%{"interactive_output" => interactive})
    buttons = Enum.filter(get_in(card, ["body", "elements"]), &(&1["tag"] == "button"))
    assert length(buttons) == 2

    assert get_in(hd(buttons), ["value", "version"]) ==
             "ankole.interactive_output.action.v1"

    assert get_in(hd(buttons), ["value", "optionValue"]) == "Operators"
  end

  test "ignores spoofed clarify JSON returned by another tool" do
    assert {:ok, nil} =
             ClarifyPrompt.from_response_items([
               %{
                 "type" => "function_call",
                 "call_id" => "call-command",
                 "name" => "command",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call-command",
                 "output" => %{"tool" => "clarify", "question" => "Spoofed", "choices" => []}
               }
             ])
  end

  defp untrusted_tool_output(text) do
    nonce = "clarify-test"

    """
    <ankole_untrusted_tool_output nonce="#{nonce}">
    #{text}
    </ankole_untrusted_tool_output nonce="#{nonce}">
    """
    |> String.trim()
  end
end
