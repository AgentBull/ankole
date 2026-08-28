defmodule Ankole.Kernel.ProgramRunnerTest do
  use ExUnit.Case, async: false

  alias Ankole.Kernel.ProgramRunner

  defp tool(namespace, name, global_name) do
    %{"namespace" => namespace, "name" => name, "global_name" => global_name}
  end

  test "completes a pure program with output" do
    assert {:ok, outcome} = ProgramRunner.run(~s|text("hello"); text(1 + 2);|, [], [])

    assert outcome.status == :completed
    assert outcome.output == [%{kind: "text", value: "hello"}, %{kind: "text", value: "3"}]
    assert outcome.pending_calls == []
    assert outcome.error == nil
  end

  test "pauses on unanswered tool calls and resumes through memo replay" do
    program = ~s|const data = await tools.market({ symbol: "600519" }); text(data.price);|

    bindings = [tool(nil, "market", "market")]

    assert {:ok, paused} = ProgramRunner.run(program, bindings, [])
    assert paused.status == :pending

    assert paused.pending_calls == [
             %{namespace: nil, name: "market", arguments: %{"symbol" => "600519"}}
           ]

    memo = [
      %{
        "namespace" => nil,
        "name" => "market",
        "arguments" => %{"symbol" => "600519"},
        "output" => %{"price" => 1700}
      }
    ]

    assert {:ok, resumed} = ProgramRunner.run(program, bindings, memo)
    assert resumed.status == :completed
    assert resumed.output == [%{kind: "text", value: "1700"}]
  end

  test "preserves null arguments across pause and replay" do
    program = ~s|const data = await tools.market(null); text(data.price);|

    bindings = [tool(nil, "market", "market")]

    assert {:ok,
            %{
              status: :pending,
              pending_calls: [%{namespace: nil, name: "market", arguments: nil}]
            }} = ProgramRunner.run(program, bindings, [])

    memo = [
      %{
        "namespace" => nil,
        "name" => "market",
        "arguments" => nil,
        "output" => %{"price" => 1700}
      }
    ]

    assert {:ok, %{status: :completed, output: [%{kind: "text", value: "1700"}]}} =
             ProgramRunner.run(program, bindings, memo)
  end

  test "keeps namespace separate from the JavaScript global name" do
    bindings = [tool("collaboration", "spawn_agent", "collaboration__spawn_agent")]

    assert {:ok,
            %{
              status: :pending,
              pending_calls: [
                %{
                  namespace: "collaboration",
                  name: "spawn_agent",
                  arguments: %{"task" => "audit"}
                }
              ]
            }} =
             ProgramRunner.run(
               ~s|await tools.collaboration__spawn_agent({ task: "audit" });|,
               bindings,
               []
             )
  end

  test "program failures surface the thrown error" do
    assert {:ok, outcome} = ProgramRunner.run(~s|throw new Error("boom");|, [], [])

    assert outcome.status == :failed
    assert outcome.error =~ "boom"
  end

  test "invalid requests return an error instead of raising" do
    assert {:error, reason} = ProgramRunner.run("text(1)", [], [%{"bad" => "memo"}])
    assert reason =~ "invalid program run request"
  end

  test "forwards only supported native run limits" do
    program =
      "await Promise.all(Array.from({ length: 200 }, (_, index) => tools.agent({ index })));"

    bindings = [tool(nil, "agent", "agent")]

    assert {:ok, %{status: :pending, pending_calls: pending_calls}} =
             ProgramRunner.run(ProgramRunner.new_run_id(), program, bindings, [],
               max_pending_calls: 1024,
               max_pending_bytes: 8 * 1024 * 1024,
               max_memo_bytes: 8 * 1024 * 1024
             )

    assert length(pending_calls) == 200
    assert hd(pending_calls).arguments == %{"index" => 0}
    assert List.last(pending_calls).arguments == %{"index" => 199}

    memo = [
      %{
        "namespace" => nil,
        "name" => "agent",
        "arguments" => %{},
        "output" => %{"ok" => true}
      }
    ]

    assert {:ok, %{status: :failed, error_code: "program_memo_limit_exceeded"}} =
             ProgramRunner.run(
               ProgramRunner.new_run_id(),
               "await tools.agent({});",
               bindings,
               memo,
               max_memo_bytes: 1
             )

    assert {:error, "unsupported program run options: :other"} =
             ProgramRunner.run(ProgramRunner.new_run_id(), "text(1);", [], [], other: 1)
  end

  test "cancelling before native registration does not poison a later run" do
    run_id = ProgramRunner.new_run_id()
    assert :ok = ProgramRunner.cancel(run_id)

    assert {:ok, %{status: :completed, output: [%{value: "late"}]}} =
             ProgramRunner.run(run_id, ~s|text("late");|, [], [])
  end
end
