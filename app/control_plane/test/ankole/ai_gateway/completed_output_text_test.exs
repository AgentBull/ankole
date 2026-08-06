defmodule Ankole.AIGateway.CompletedOutputTextTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway

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
