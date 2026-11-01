defmodule Ankole.Sessions.TurnTest do
  use Ankole.DataCase, async: true
  alias Ankole.Sessions.Turn
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tools
  alias Ankole.Sessions.{PendingCall, Tool, ToolResult, Wait, Worker}
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Signals.Signal

  test "clarification ends a direct turn (G4)" do
    call = %{"type" => "function_call", "name" => "clarify", "call_id" => "c1"}

    run = %{
      run("", [call])
      | results: %{"c1" => %Ankole.Sessions.ToolResult{terminate: true}}
    }

    assert {%Turn{stage: :finalizing}, [{:finalize, _, _}]} = boundary(run)
  end

  test "iteration exhaustion permits one synthesis with no tools (G4, G8)" do
    call = %{"type" => "function_call", "name" => "command", "call_id" => "c1"}
    run = %{run("", [call]) | iteration: 3}
    assert {%Turn{run: next}, [{:next, :request}]} = boundary(run)
    assert next.outcome == :iteration_exhausted
    assert next.tools == [] and next.hosted_tools == []
    assert hd(next.input)["content"] |> hd() |> Map.fetch!("text") =~ "max_model_iterations=3"

    assert {%Turn{stage: :finalizing}, [{:finalize, _, _}]} =
             boundary(%{
               next
               | model_response: response("Done", []),
                 round_calls: [],
                 input: [],
                 iteration: 4
             })

    assert {%Turn{stage: :finalizing}, [{:finalize, _, _}]} =
             boundary(%{next | iteration: 4, input: []})
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

    assert {%Turn{run: next}, [{:next, :request}]} = boundary(run)
    assert [%{"call_id" => "c1", "output" => output}, note] = next.input
    assert output =~ "cut off"
    assert hd(note["content"])["text"] =~ "output token limit"
    assert {%Turn{stage: :finalizing}, [{:finalize, _, _}]} = boundary(next)

    # The only call can be the cut-off one, which is not executable.
    assert {%Turn{run: next}, [{:next, :request}]} =
             boundary(%{truncated(run("", [cut])) | round_calls: []})

    assert [%{"role" => "user"}] = next.input

    # Text cut off without calls keeps the partial answer.
    refute Run.truncated?(truncated(run("partial", [])).model_response)
  end

  test "the Driver executes client calls and leaves hosted Brain calls to AIGateway" do
    brain = %{
      "type" => "brain_call",
      "call_id" => "brain-1",
      "operation" => "remember",
      "arguments" => %{"claim" => "The test number is 742284."},
      "status" => "completed"
    }

    output = %{
      "type" => "brain_output",
      "call_id" => "brain-1",
      "status" => "completed",
      "output" => %{"inserted" => true}
    }

    function = %{
      "type" => "function_call",
      "call_id" => "command-1",
      "name" => "command",
      "arguments" => "{}",
      "status" => "completed"
    }

    custom = %{
      "type" => "custom_tool_call",
      "call_id" => "custom-1",
      "name" => "custom",
      "input" => "test input",
      "status" => "completed"
    }

    assert Run.executable_calls(response("Remembered", [brain, output, function, custom])) ==
             [function, custom]

    assert Run.executable_calls(response("Remembered", [brain, output])) == []
    assert Run.executable_calls(response("", [brain])) == []

    completed = run("Remembered", [brain, output])

    assert {%Turn{stage: :finalizing}, [{:finalize, _, _}]} =
             boundary(%{completed | round_calls: []})
  end

  test "a Workflow task reports failure at the iteration cap and after a second truncation (G4)" do
    call = %{"type" => "function_call", "name" => "web_search", "call_id" => "c1"}
    run = %{run("", [call]) | kind: :workflow_task, iteration: 3}
    assert {%Turn{run: next}, [{:next, :request}]} = boundary(run)
    assert next.outcome == :iteration_exhausted

    assert {%Turn{stage: :finalizing},
            [{:workflow_failure, %{"code" => "schema_noncompliance", "retryable" => false}}]} =
             boundary(%{
               next
               | model_response: response("Summary", []),
                 round_calls: [],
                 input: [],
                 iteration: 4
             })

    run = %{truncated(run("partial", [call])) | kind: :workflow_task, truncated_rounds: 1}

    assert {%Turn{stage: :finalizing}, [{:workflow_failure, %{"code" => "schema_noncompliance"}}]} =
             boundary(run)
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
    assert {%Turn{run: nudged}, [{:next, :request}]} = boundary(run)
    assert nudged.nudged
    assert {%Turn{run: repaired}, [{:next, :request}]} = boundary(%{nudged | input: []})
    assert repaired.repaired
    assert {%Turn{stage: :finalizing}, [{:finalize, _, _}]} = boundary(%{repaired | input: []})
  end

  test "scheduled ordinary text completes as a visible reply" do
    run = %{run("TICK", []) | kind: :scheduled}
    assert {%Turn{stage: :finalizing, run: finished}, [{:finalize, _, _}]} = boundary(run)
    refute finished.repaired

    assert {:ok, %{final_text: "TICK"}} =
             Ankole.Sessions.Scheduled.project_completion(finished, %{final_text: "TICK"})
  end

  test "scheduled empty text cannot complete as silent success without its tool" do
    run = %{run("", []) | kind: :scheduled}

    assert {:error, :scheduled_turn_not_finished} =
             Ankole.Sessions.Scheduled.project_completion(run, %{final_text: "  "})
  end

  test "a repeated failure warning compares semantic input and excludes volatile keys (G4)" do
    call = %{"name" => "command", "arguments" => ~s({"command":"pwd","request_id":"one"})}
    first = Turn.track_failure(run("", []), call, Tools.error("failed"))

    second =
      Turn.track_failure(
        first,
        Map.put(call, "arguments", ~s({"request_id":"two","command":"pwd"})),
        Tools.error("failed")
      )

    assert length(second.follow_ups) == 1

    assert hd(second.follow_ups)["content"] |> hd() |> Map.fetch!("text") =~
             "repeated_tool_failure"

    warning = hd(second.follow_ups)["content"] |> hd() |> Map.fetch!("text")
    assert warning =~ "computer is unavailable"
    assert warning =~ "explain the blocker without another computer call"
    refute warning =~ "Do not switch to text-only replies"

    assert Turn.track_failure(second, call, Tools.result(%{})).repeated_failure == nil
  end

  test "recovery reads durable controls before resuming and rejects a superseded resume" do
    run = %{run("", []) | pending_event_ids: ["stop", "steer"]}
    turn = turn(run, :preparing)

    assert {ready,
            [
              {:next, {:inbox, "stop"}},
              {:next, {:inbox, "steer"}},
              {:next, {:resume, 1, :preparing}}
            ]} =
             Turn.step(turn, {:completed, :prepare, {:ok, {:preparing, run}}})

    assert ready.stage == :boundary
    event = signal("stop", "command.stop")

    assert {interrupted, [:cancel_current, {:interrupt, ^event}]} =
             Turn.step(ready, {:completed, {:inbox, event.id}, event})

    replacement = %{run | epoch: 2, signal_id: "replacement"}
    {preparing, [:prepare]} = Turn.step(interrupted, {:completed, :control, {:ok, replacement}})
    assert {^preparing, []} = Turn.step(preparing, {:resume, 1, :preparing})
  end

  for stage <- [:admitting, :preparing, :recording, :finalizing] do
    test "#{stage} completes its operation before handling inbox controls" do
      turn = turn(run("", []), unquote(stage))
      assert {^turn, [:postpone]} = Turn.step(turn, {:inbox, "stop"})
    end
  end

  test "ambient classification can settle without admitting a foreground Run" do
    event = signal("ambient", "im.message.may_intervene")
    turn = %Turn{key: %{agent_uid: "test", session_id: "test"}, event: event}
    assert {classifying, [:classify_input]} = Turn.step(turn, :admit)

    assert {^classifying, [:ambient_triage]} =
             Turn.step(classifying, {:completed, :input_kind, :ambient})

    assert classifying.stage == :admitting
    assert classifying.run == nil

    assert {settled, commands} =
             Turn.step(classifying, {:completed, :ambient_triage, {:ok, :settled}})

    assert settled.run == nil
    assert {:next, :rebuild} in commands
    refute :prepare in commands

    assert {ready, [:admit]} =
             Turn.step(classifying, {:completed, :ambient_triage, {:ok, :intervene, event}})

    assert ready.event == event

    due = %{event | available_at: DateTime.add(DateTime.utc_now(), 30)}

    assert {deferred, [{:wait_until, at, :admit}]} =
             Turn.step(classifying, {:completed, :ambient_triage, {:ok, :deferred, due}})

    assert deferred.stage == :deferred
    assert at == due.available_at
  end

  test "a retryable failure waits for a committed deadline before backing off" do
    turn = turn(run("", []), :requesting_model)
    error = %{"code" => "upstream_unavailable", "retryable" => true}
    {failed, commands} = Turn.step(turn, {:completed, :model, {:error, error}})
    assert {:defer_retry, error} in commands
    refute Enum.any?(commands, &match?({:wait_until, _, _}, &1))

    deadline = ~U[2026-10-22 00:00:30.000000Z]
    event = %{turn.run.event | available_at: deadline}

    assert {%{stage: :backing_off}, [{:wait_until, ^deadline, :admit}]} =
             Turn.step(failed, {:completed, :defer_retry, {:ok, event}})

    assert {_, [{:stop, {:defer_retry_failed, :database_unavailable}}]} =
             Turn.step(failed, {:completed, :defer_retry, {:error, :database_unavailable}})
  end

  for reason <- [:stale_driver, :run_closed] do
    test "#{reason} ends every completion path without another domain write" do
      turn = turn(run("", []), :executing_tools)

      for kind <- [
            :admit,
            :prepare,
            :model,
            :record,
            :boundary,
            :finalize,
            :observe,
            :worker_resolve,
            :worker_open,
            :worker_check,
            :defer_retry,
            {:tool, "c1"},
            {:worker_send, "c1"}
          ] do
        assert {^turn, [{:refund, :stale_driver}, {:stop, :normal}]} =
                 Turn.step(turn, {:completed, kind, {:error, unquote(reason)}})
      end
    end
  end

  test "committed results are restored before any Worker is acquired" do
    call = call("done")
    result = Tools.result(%{"saved" => true})
    run = %{tool_run([call]) | receipts: %{"done" => result}, recovered?: true}

    {restored, commands} =
      Turn.step(turn(run, :boundary), {:resume, run.epoch, :executing_tools}, 0)

    assert restored.run.results == %{"done" => result}
    assert restored.pending == %{}
    refute :resolve_worker in commands
    assert {%{stage: :recording}, [:record]} = Turn.step(restored, :tools, 0)
  end

  test "a terminal result cancels queued calls but waits for calls already in flight" do
    calls = Enum.map(1..5, &call("c#{&1}"))
    turn = ready_tools(calls)
    {running, commands} = Turn.step(turn, :tools, 0)
    assert length(Enum.filter(commands, &match?({:send_tool, _, _, _}, &1))) == 4
    assert running.pending["c5"].status == :queued

    {ending, _} = Turn.step(running, {:completed, {:tool, "c1"}, %ToolResult{terminate: true}})
    assert ending.run.results["c5"].is_error
    assert map_size(ending.pending) == 3
    assert {_, commands} = Turn.step(ending, :tools, 1)
    refute :record in commands
    refute Enum.any?(commands, &match?({:send_tool, _, _, _}, &1))

    finished =
      Enum.reduce(2..4, ending, fn id, turn ->
        {turn, _} = Turn.step(turn, {:completed, {:tool, "c#{id}"}, Tools.result(%{})})
        turn
      end)

    assert {%{stage: :recording} = recording, [:record]} = Turn.step(finished, :tools, 2)
    assert recording.run.calls == calls

    {committed, commands} =
      Turn.step(recording, {:completed, :record, {:ok, %{message: %{id: "journal"}}}}, 3)

    assert committed.run.anchor == "journal"
    assert committed.run.calls == []
    assert committed.stage == :boundary
    assert :cancel_round_tasks in commands
    assert {:next, :boundary} in commands
  end

  test "sequential tools wait for parallel results and block later calls" do
    calls = [call("first"), %{call("serial") | "name" => "serial"}, call("last")]
    turn = ready_tools(calls)

    serial = %{
      hd(turn.run.tools)
      | name: "serial",
        schema: %{"name" => "serial"},
        execution_mode: "sequential"
    }

    turn = %{turn | run: %{turn.run | tools: turn.run.tools ++ [serial]}}
    {running, commands} = Turn.step(turn, :tools, 0)

    assert [{:send_tool, _, _, %{call: %{"call_id" => "first"}}}] =
             Enum.filter(commands, &match?({:send_tool, _, _, _}, &1))

    {running, _} = Turn.step(running, {:completed, {:tool, "first"}, Tools.result(%{})})
    {running, commands} = Turn.step(running, :tools, 1)

    assert [{:send_tool, _, _, %{call: %{"call_id" => "serial"}}}] =
             Enum.filter(commands, &match?({:send_tool, _, _, _}, &1))

    assert running.pending["last"].status == :queued
  end

  test "an adopted unsafe call probes and reports an unknown result without executing it again" do
    turn = ready_tools([call("unsafe")], true)
    {running, commands} = Turn.step(turn, :tools, 0)

    assert {:send_tool, _, _, %{mode: "probe"}} =
             Enum.find(commands, &match?({:send_tool, _, _, _}, &1))

    {finished, _} = Turn.step(running, {:completed, :worker, {:unknown, "unsafe"}})
    assert finished.run.results["unsafe"].is_error
    assert finished.run.results["unsafe"].output =~ "result is unknown"
    assert {%{stage: :recording}, [:record]} = Turn.step(finished, :tools)
  end

  test "Worker demand and resolution without an open do not send a close" do
    run = tool_run([call("c1")])
    event = %{"type" => "response.output_item.added", "item" => call("c1")}

    {requested, [:request_worker]} =
      Turn.step(turn(run, :requesting_model), {:model_events, [event]}, 0)

    {tools, _} = Turn.step(turn(run, :boundary), {:resume, run.epoch, :executing_tools}, 0)
    {opening, _} = Turn.step(tools, :tools, 1)
    {waiting, _} = Turn.step(opening, {:completed, :worker_resolve, {:wait, :capacity}}, 2)

    {unavailable, _} =
      Turn.step(opening, {:completed, :worker_resolve, {:error, :worker_provider_missing}}, 2)

    for current <- [requested, opening, waiting, unavailable] do
      {_, commands} = Turn.step(current, {:completed, :finalize, {:ok, :done}}, 3)
      refute Enum.any?(commands, &match?({:close_worker, _}, &1))
    end
  end

  test "a workspace open remains owed a close across a committed round" do
    run = tool_run([call("c1")])
    row = %{transport_route: "test"}
    {tools, _} = Turn.step(turn(run, :boundary), {:resume, run.epoch, :executing_tools}, 0)
    {opening, _} = Turn.step(tools, :tools, 1)

    {opened, commands} =
      Turn.step(opening, {:completed, :worker_resolve, {:ok, row, :envelope}}, 2)

    assert {:open_worker, row, :envelope} in commands

    {committed, _} =
      Turn.step(opened, {:completed, :record, {:ok, %{message: %{id: "journal"}}}}, 3)

    assert committed.acquisition == {:idle, :requested}

    {rebuilt, commands} = Turn.step(committed, {:completed, :finalize, {:ok, :done}}, 4)
    assert [{:close_worker, _}] = Enum.filter(commands, &match?({:close_worker, _}, &1))
    refute rebuilt.workspace_open_attempted?
  end

  test "Worker acquisition uses one deadline and stops accepting events after the round commits" do
    run = tool_run([call("c1")])
    {turn, _} = Turn.step(turn(run, :boundary), {:resume, run.epoch, :executing_tools}, 100)
    {opening, commands} = Turn.step(turn, :tools, 100)
    assert :resolve_worker in commands
    {waiting, _} = Turn.step(opening, {:completed, :worker_resolve, {:wait, :capacity}}, 200)
    assert {:waiting, :capacity, 100} = waiting.acquisition
    {expired, _} = Turn.step(waiting, {:worker_timeout, :expired}, 60_100)
    assert expired.run.results["c1"].is_error
    assert expired.run.results["c1"].output =~ "busy with other tasks"
    {recording, [:record]} = Turn.step(expired, :tools, 60_101)

    {committed, _} =
      Turn.step(recording, {:completed, :record, {:ok, %{message: %{id: "journal"}}}}, 60_102)

    assert {^committed, []} = Turn.step(committed, {:worker_timeout, :check}, 60_103)
    payload = %{run: Worker.ref(run), reason: :READY, error: ""}
    assert {^committed, []} = Turn.step(committed, {:worker, :workspace_ready, payload}, 60_104)
  end

  test "an old response cannot contribute a result to the current tool round" do
    turn = ready_tools([call("c1")])
    payload = %{run: Worker.ref(turn.run), response_id: "resp_old", call_id: "c1"}
    assert {^turn, []} = Turn.step(turn, {:worker, :tool_result, payload})
    current = %{payload | response_id: Run.response_id(turn.run.model_response)}

    assert {^turn, [{:decode_worker, :tool_result, ^current}]} =
             Turn.step(turn, {:worker, :tool_result, current})
  end

  test "inbox steering observes a committed wait once and consumes its observed input IDs" do
    run = tool_run([call("waiting")])
    wait = %Wait{kind: :job, job_id: "job", timeout_ms: 10_000}
    run = %{run | receipts: %{"waiting" => {:await, wait}}}
    {turn, _} = Turn.step(turn(run, :boundary), {:resume, 1, :executing_tools})
    event = signal("steer", "command.steer")
    {observing, commands} = Turn.step(turn, {:completed, {:inbox, event.id}, event})
    assert :observe in commands
    assert observing.run.pending_event_ids == [event.id]
    assert {^observing, []} = Turn.step(observing, {:completed, {:inbox, event.id}, event})
    {_, commands} = Turn.step(observing, :poll)
    refute :observe in commands
    result = Tools.result(%{"state" => "ready"})

    {finished, _} =
      Turn.step(observing, {:completed, :observe, [{"waiting", {:ready, result, [event.id]}}]})

    assert finished.run.wait_event_ids == [event.id]
    refute finished.observing?
    assert {%{stage: :recording}, [:record]} = Turn.step(finished, :tools)
  end

  defp signal(id, type),
    do: %Signal{
      id: id,
      agent_uid: "test",
      session_id: "test",
      producer: :kernel,
      type: type,
      status: :queued,
      data: %{}
    }

  defp call(id),
    do: %{"type" => "function_call", "call_id" => id, "name" => "command", "arguments" => "{}"}

  defp turn(run, stage),
    do: %Turn{
      key: %{agent_uid: run.agent_uid, session_id: run.session_id},
      run: run,
      stage: stage
    }

  defp tool_run(calls) do
    agent = Ankole.SessionsCase.agent_fixture().principal
    run = run("", calls)

    %{
      run
      | agent_uid: agent.uid,
        event: %{run.event | agent_uid: agent.uid, authorization_kind: "service"},
        calls: calls,
        tools: [Tool.new(%{"name" => "command", "parameters" => %{"type" => "object"}}, :worker)]
    }
  end

  defp ready_tools(calls, recovered? \\ false) do
    run = %{tool_run(calls) | recovered?: recovered?}

    %{
      turn(run, :executing_tools)
      | pending: PendingCall.new_round(calls, recovered?),
        acquisition: {:ready, %{transport_route: "test"}}
    }
  end

  defp boundary(run),
    do:
      Turn.step(
        %Turn{
          key: %{agent_uid: run.agent_uid, session_id: run.session_id},
          stage: :boundary,
          run: run
        },
        {:completed, :boundary, {:ok, run}}
      )

  defp run(text, calls) do
    %Run{
      agent_uid: "test",
      session_id: "test",
      signal_id: "event",
      epoch: 1,
      event: %Signal{producer: :kernel, type: "conversation.message.addressed", data: %{}},
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
