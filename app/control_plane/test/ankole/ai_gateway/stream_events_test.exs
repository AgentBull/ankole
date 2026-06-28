defmodule Ankole.AIGateway.StreamEventsTest do
  use Ankole.AIGatewayCase

  test "response_stream_events emits semantic refusal deltas and terminal failure states" do
    body = %{
      "id" => "resp_refusal",
      "object" => "response",
      "status" => "failed",
      "output" => [
        %{
          "id" => "msg_refusal",
          "type" => "message",
          "status" => "completed",
          "role" => "assistant",
          "content" => [%{"type" => "refusal", "refusal" => "I cannot help with that."}]
        }
      ]
    }

    events = AIGateway.response_stream_events(body)

    assert Enum.map(events, & &1["type"]) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.refusal.delta",
             "response.refusal.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.failed"
           ]

    assert %{"delta" => "I cannot help with that."} =
             Enum.find(events, &(&1["type"] == "response.refusal.delta"))

    assert %{"refusal" => "I cannot help with that."} =
             Enum.find(events, &(&1["type"] == "response.refusal.done"))

    assert List.last(AIGateway.response_stream_events(%{body | "status" => "incomplete"}))[
             "type"
           ] == "response.incomplete"
  end

  test "response_stream_events emits reasoning summary_text semantic events" do
    body = %{
      "id" => "resp_reasoning",
      "object" => "response",
      "status" => "completed",
      "output" => [
        %{
          "id" => "rs_1",
          "type" => "reasoning",
          "status" => "completed",
          "summary" => [
            %{
              "type" => "summary_text",
              "text" => "Checked the constraints and selected the shortest valid answer."
            }
          ],
          "encrypted_content" => nil
        }
      ]
    }

    events = AIGateway.response_stream_events(body)

    assert Enum.map(events, & &1["type"]) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.summary_text.delta",
             "response.summary_text.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.completed"
           ]

    assert %{"delta" => "Checked the constraints and selected the shortest valid answer."} =
             Enum.find(events, &(&1["type"] == "response.summary_text.delta"))
  end
end
