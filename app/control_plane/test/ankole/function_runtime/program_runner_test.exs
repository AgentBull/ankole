defmodule Ankole.FunctionRuntime.ProgramRunnerTest do
  use ExUnit.Case, async: false

  alias Ankole.FunctionRuntime.ProgramRunner

  test "replays one tool transcript with structured identities and null arguments" do
    binding = %{"namespace" => "test", "name" => "lookup", "global_name" => "lookup"}
    program = "const result = await tools.lookup(null); text(result.answer);"

    assert {:ok, %{status: :pending, pending_calls: [call]}} =
             ProgramRunner.run(program, [binding], [])

    assert call == %{namespace: "test", name: "lookup", arguments: nil}

    memo = [
      %{
        "namespace" => "test",
        "name" => "lookup",
        "arguments" => nil,
        "output" => %{"answer" => 42}
      }
    ]

    assert {:ok, %{status: :completed, output: [%{kind: "text", value: "42"}]}} =
             ProgramRunner.run(program, [binding], memo)
  end

  test "cancellation before execution returns the cancelled outcome without starting user code" do
    handle = ProgramRunner.new_handle()
    assert :ok = ProgramRunner.cancel(handle)

    assert {:ok, %{status: :failed, error_code: "program_cancelled"}} =
             ProgramRunner.run(handle, "for (;;) {}", [], [])

    assert ProgramRunner.active_runs() == 0
  end

  test "execution handles run once and retain the supported option boundary" do
    handle = ProgramRunner.new_handle()
    assert {:ok, %{status: :completed}} = ProgramRunner.run(handle, "text(1)", [], [])
    assert {:error, _} = ProgramRunner.run(handle, "text(2)", [], [])

    assert {:error, "unsupported program run options: :other"} =
             ProgramRunner.run(ProgramRunner.new_handle(), "text(3)", [], [], other: 1)
  end

  test "CPU timeout completes without occupying a BEAM scheduler" do
    handle = ProgramRunner.new_handle()

    assert {:ok, %{status: :failed, error_code: "program_timeout"}} =
             ProgramRunner.run(handle, "for (;;) {}", [], [], timeout_ms: 100)

    assert ProgramRunner.active_runs() == 0
    assert {:ok, %{status: :completed}} = ProgramRunner.run("text(1)", [], [])
  end

  test "owner exit cancels a live HTTP execution and releases the local endpoint lease" do
    parent = self()

    owner =
      spawn(fn ->
        handle = ProgramRunner.new_handle()
        {:ok, ^handle} = ProgramRunner.start(handle, "for (;;) {}", [], [], timeout_ms: 2_000)
        send(parent, :started)
        ProgramRunner.await(handle)
      end)

    assert_receive :started
    assert ProgramRunner.active_runs() == 1
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert eventually(fn -> ProgramRunner.active_runs() == 0 end)
  end

  test "heap quota failure preserves its error code and leaves the next run available" do
    program = "const blocks=[];for(let i=0;i<384;i++)blocks.push(new Array(262144).fill(i));"

    assert {:ok,
            %{
              status: :failed,
              error_code: "program_heap_limit_exceeded",
              output: [],
              pending_calls: []
            }} =
             ProgramRunner.run(ProgramRunner.new_handle(), program, [], [], timeout_ms: 10_000)

    assert {:ok, %{status: :completed, output: [%{kind: "text", value: "1"}]}} =
             ProgramRunner.run("text(1)", [], [])
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
