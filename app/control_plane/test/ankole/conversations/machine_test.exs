defmodule Ankole.Conversations.MachineTest do
  use ExUnit.Case, async: true
  alias Ankole.Conversations.{Machine, Run, Tools}
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.SignalsGateway.ActorEvent

  test "clarification ends a direct turn (G4)" do
    call = %{"type" => "function_call", "name" => "clarify", "call_id" => "c1"}

    run = %{
      run("", [call])
      | results: %{"c1" => %Ankole.Conversations.ToolResult{terminate: true}}
    }

    assert {:finalize, _} = Machine.next(run)
  end

  test "iteration exhaustion permits one synthesis with no tools (G4, G8)" do
    call = %{"type" => "function_call", "name" => "command", "call_id" => "c1"}
    run = %{run("", [call]) | iteration: 3}
    assert {:request, next} = Machine.next(run)
    assert next.outcome == "iteration_exhausted"
    assert next.tools == [] and next.hosted_tools == []
    assert hd(next.input)["content"] |> hd() |> Map.fetch!("text") =~ "max_model_iterations=3"

    assert {:finalize, _} =
             Machine.next(%{
               next
               | model_response: response("Done", []),
                 round_calls: [],
                 input: [],
                 iteration: 4
             })

    assert {:finalize, _} = Machine.next(%{next | iteration: 4, input: []})
  end

  test "two truncated calls terminate the retry instead of executing partial input (G4, G8)" do
    complete = %{
      "type" => "function_call",
      "name" => "command",
      "call_id" => "c1",
      "arguments" => "{}",
      "status" => "completed"
    }

    cut = %{
      "type" => "function_call",
      "name" => "command",
      "call_id" => "c2",
      "arguments" => "{",
      "status" => "incomplete"
    }

    run = truncated(run("", [complete, cut]))
    assert Run.executable_calls(run.model_response) == [complete]
    run = %{run | round_calls: [complete]}

    assert {:request, next} = Machine.next(run)
    assert [%{"call_id" => "c1", "output" => output}, note] = next.input
    assert output =~ "cut off"
    assert hd(note["content"])["text"] =~ "output token limit"
    assert {:finalize, _} = Machine.next(next)

    # The only call can be the cut-off one, which is not executable.
    assert {:request, next} = Machine.next(%{truncated(run("", [cut])) | round_calls: []})
    assert [%{"role" => "user"}] = next.input

    # Text cut off without calls keeps the partial answer.
    refute Run.truncated?(truncated(run("partial", [])).model_response)
  end

  test "a Workflow task reports failure at the iteration cap and after a second truncation (G4)" do
    call = %{"type" => "function_call", "name" => "web_search", "call_id" => "c1"}
    run = %{run("", [call]) | kind: :workflow_task, iteration: 3}
    assert {:request, next} = Machine.next(run)
    assert next.outcome == "iteration_exhausted"

    assert {:workflow_failure, _, %{"code" => "schema_noncompliance", "retryable" => false}} =
             Machine.next(%{
               next
               | model_response: response("Summary", []),
                 round_calls: [],
                 input: [],
                 iteration: 4
             })

    run = %{truncated(run("partial", [call])) | kind: :workflow_task, truncated_rounds: 1}
    assert {:workflow_failure, _, %{"code" => "schema_noncompliance"}} = Machine.next(run)
  end

  defp truncated(run) do
    metadata = %{
      "stop_reason" => "max_output_tokens",
      "incomplete_details" => %{"reason" => "max_output_tokens"}
    }

    %{run | model_response: %{run.model_response | metadata: metadata}}
  end

  test "empty responses after tools have a bounded nudge and visible repair (G4)" do
    run = %{run("", []) | saw_tool_results: true}
    assert {:request, nudged} = Machine.next(run)
    assert nudged.nudged
    assert {:request, repaired} = Machine.next(%{nudged | input: []})
    assert repaired.repaired
    assert {:finalize, _} = Machine.next(%{repaired | input: []})
  end

  test "scheduled output has strict shape and one repair without redoing tools (G4)" do
    for invalid <- [
          "<silent_success/>",
          "raw text",
          ~s({"outcome":"reply","reply":" "}),
          ~s({"outcome":"reply","reply":"hi","extra":true})
        ] do
      run = %{run(invalid, []) | kind: :scheduled}
      assert {:request, repaired} = Machine.next(run)
      assert repaired.repaired and repaired.tools == [] and repaired.hosted_tools == []
      assert {:finalize, _} = Machine.next(%{repaired | input: []})
    end
  end

  test "a repeated failure warning compares semantic input and excludes volatile keys (G4)" do
    call = %{"name" => "command", "arguments" => ~s({"command":"pwd","request_id":"one"})}
    first = Machine.failure(run("", []), call, Tools.error("failed"))

    second =
      Machine.failure(
        first,
        Map.put(call, "arguments", ~s({"request_id":"two","command":"pwd"})),
        Tools.error("failed")
      )

    assert length(second.follow_ups) == 1

    assert hd(second.follow_ups)["content"] |> hd() |> Map.fetch!("text") =~
             "repeated_tool_failure"

    assert Machine.failure(second, call, Tools.result(%{})).repeated_failure == nil
  end

  defp run(text, calls) do
    %Run{
      agent_uid: "test",
      session_id: "test",
      actor_event_id: "event",
      epoch: 1,
      event: %ActorEvent{type: "im.message.addressed", payload: %{}},
      spec: %{request_context: %{"ai_agent" => %{"max_iterations" => 3}}},
      model_response: response(text, calls),
      round_calls: calls,
      tools: [%{"name" => "command"}],
      hosted_tools: [%{"type" => "brain"}]
    }
  end

  defp response(text, calls),
    do: %Message{
      metadata: %{},
      content:
        calls ++
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => text}]
            }
          ]
    }
end
