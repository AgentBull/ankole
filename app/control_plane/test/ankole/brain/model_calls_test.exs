defmodule Ankole.Brain.ModelCallsTest do
  use ExUnit.Case, async: true

  alias Ankole.Brain.ModelCalls

  describe "decode_json_object/1" do
    test "decodes a bare object" do
      assert {:ok, %{"facts" => []}} = ModelCalls.decode_json_object(~s({"facts": []}))
    end

    test "decodes analysis prose followed by a bare object" do
      # Models without structured output, for example DeepSeek, put their
      # full analysis in output_text and append the JSON at the end.
      text = """
      Let me analyze this conversation step by step.
      The user mentioned a product called Cobalt-593.
      Here is the extraction result:
      {"facts": [{"claim": "Cobalt-593 launched", "kind": "event"}], "takes": []}
      """

      assert {:ok, %{"facts" => [%{"claim" => "Cobalt-593 launched"}]}} =
               ModelCalls.decode_json_object(text)
    end

    test "decodes the last fenced block after analysis" do
      text = """
      Analysis with an inline example: `{"not": "this"}` is the shape.

      ```json
      {"facts": [], "takes": [{"claim": "prefer weekly summaries"}]}
      ```
      """

      assert {:ok, %{"takes" => [%{"claim" => "prefer weekly summaries"}]}} =
               ModelCalls.decode_json_object(text)
    end

    test "prefers the whole text when it already is the object" do
      text = ~s({"nested": {"a": 1}, "note": "contains } and { in strings"})
      assert {:ok, %{"nested" => %{"a" => 1}}} = ModelCalls.decode_json_object(text)
    end

    test "fails when no candidate is a JSON object" do
      assert {:error, :model_output_not_json} =
               ModelCalls.decode_json_object("I could not produce a result.")

      assert {:error, :model_output_not_json} = ModelCalls.decode_json_object(~s(["array"]))
    end

    test "takes the last balanced object when the output carries several" do
      # A first-to-last brace slice would fuse both objects into invalid
      # JSON; the balanced scan keeps them separate and the final answer
      # comes last.
      text = """
      Draft attempt: {"items": [{"claim": "wrong draft"}]}
      Corrected result:
      {"items": [{"claim": "final answer", "kind": "fact"}]}
      """

      assert {:ok, %{"items" => [%{"claim" => "final answer"}]}} =
               ModelCalls.decode_json_object(text)
    end

    test "balanced scan ignores braces inside strings" do
      text = ~s(prose {"a": "left { and right }", "b": 2} trailing)
      assert {:ok, %{"a" => "left { and right }", "b" => 2}} = ModelCalls.decode_json_object(text)
    end

    test "an unbalanced trailing brace does not break earlier objects" do
      text = ~s(first: {"ok": true} then a dangling { at the end)
      assert {:ok, %{"ok" => true}} = ModelCalls.decode_json_object(text)
    end
  end
end
