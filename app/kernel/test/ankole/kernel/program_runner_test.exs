defmodule Ankole.Kernel.ProgramRunnerTest do
  use ExUnit.Case, async: false

  alias Ankole.Kernel.ProgramRunner

  test "completes a pure program with output" do
    assert {:ok, outcome} = ProgramRunner.run(~s|text("hello"); text(1 + 2);|, [], [])

    assert outcome.status == :completed
    assert outcome.output == [%{kind: "text", value: "hello"}, %{kind: "text", value: "3"}]
    assert outcome.pending_calls == []
    assert outcome.error == nil
  end

  test "pauses on unanswered tool calls and resumes through memo replay" do
    program = ~s|const data = await tools.market({ symbol: "600519" }); text(data.price);|

    assert {:ok, paused} = ProgramRunner.run(program, ["market"], [])
    assert paused.status == :pending
    assert paused.pending_calls == [%{name: "market", arguments: %{"symbol" => "600519"}}]

    memo = [
      %{
        "name" => "market",
        "arguments" => %{"symbol" => "600519"},
        "output" => %{"price" => 1700}
      }
    ]

    assert {:ok, resumed} = ProgramRunner.run(program, ["market"], memo)
    assert resumed.status == :completed
    assert resumed.output == [%{kind: "text", value: "1700"}]
  end

  test "preserves null arguments across pause and replay" do
    program = ~s|const data = await tools.market(null); text(data.price);|

    assert {:ok, %{status: :pending, pending_calls: [%{name: "market", arguments: nil}]}} =
             ProgramRunner.run(program, ["market"], [])

    memo = [%{"name" => "market", "arguments" => nil, "output" => %{"price" => 1700}}]

    assert {:ok, %{status: :completed, output: [%{kind: "text", value: "1700"}]}} =
             ProgramRunner.run(program, ["market"], memo)
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

  test "cancelling before native registration does not poison a later run" do
    run_id = ProgramRunner.new_run_id()
    assert :ok = ProgramRunner.cancel(run_id)

    assert {:ok, %{status: :completed, output: [%{value: "late"}]}} =
             ProgramRunner.run(run_id, ~s|text("late");|, [], [])
  end
end
