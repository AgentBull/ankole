defmodule Ankole.AIGateway.CompletedOutputTextTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway

  test "machine text keeps its existing part policy and newline separator" do
    body = %{
      "status" => "completed",
      "output" => [
        %{"type" => "message", "role" => "user", "content" => [%{"text" => " first "}]},
        %{"type" => "message", "content" => "historical string"},
        %{"type" => "message", "content" => [%{"type" => "text", "text" => "second "}]}
      ]
    }

    assert {:ok, "first \nsecond"} = AIGateway.completed_output_text(body)
  end

  test "returns the joined trimmed text of a completed response" do
    body = %{
      "status" => "completed",
      "output" => [
        %{"type" => "reasoning", "summary" => []},
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => "first", "annotations" => []},
            %{"type" => "output_text", "text" => "second", "annotations" => []}
          ]
        }
      ]
    }

    assert {:ok, "first\nsecond"} = AIGateway.completed_output_text(body)
  end

  test "reads only message text when a completed response includes a reasoning draft" do
    body = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "reasoning",
          "summary" => [],
          "content" => [%{"type" => "reasoning_text", "text" => ~s(draft {"x":1})}]
        },
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => ~s({"x":2})}]}
      ]
    }

    assert {:ok, ~s({"x":2})} = AIGateway.completed_output_text(body)
  end

  test "prefers the output_text convenience field when present" do
    body = %{"status" => "completed", "output_text" => "  plain answer  "}

    assert {:ok, "plain answer"} = AIGateway.completed_output_text(body)
  end

  test "rejects an incomplete response without reading its partial text" do
    body = %{
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => "max_output_tokens"},
      "usage" => %{"output_tokens" => 4_096},
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => ~s({"valid": "looking)}]
        }
      ]
    }

    assert {:error, {:incomplete_response, meta}} = AIGateway.completed_output_text(body)

    assert meta == %{
             "status" => "incomplete",
             "incomplete_details" => %{"reason" => "max_output_tokens"},
             "usage" => %{"output_tokens" => 4_096}
           }
  end

  test "reports missing text when a completed response carries none" do
    body = %{
      "status" => "completed",
      "output" => [%{"type" => "reasoning", "summary" => []}]
    }

    assert {:error, :missing_response_text} = AIGateway.completed_output_text(body)
  end
end
