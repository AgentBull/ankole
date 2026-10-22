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
             ProgramRunner.run(ProgramRunner.new_handle(), program, bindings, [],
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
               ProgramRunner.new_handle(),
               "await tools.agent({});",
               bindings,
               memo,
               max_memo_bytes: 1
             )

    assert {:error, "unsupported program run options: :other"} =
             ProgramRunner.run(ProgramRunner.new_handle(), "text(1);", [], [], other: 1)
  end

  test "cancellation before execution cannot miss the isolate" do
    handle = ProgramRunner.new_handle()
    assert :ok = ProgramRunner.cancel(handle)

    assert {:ok, %{error_code: "program_cancelled"}} =
             ProgramRunner.run(handle, "for (;;) {}", [], [])
  end

  test "timeout_ms bounds the native execution" do
    handle = ProgramRunner.new_handle()

    assert {:ok, %{status: :failed, error_code: "program_timeout"}} =
             ProgramRunner.run(handle, "for (;;) {}", [], [], timeout_ms: 20)

    assert ProgramRunner.active_runs() == 0
  end

  test "a completed handle cannot start another execution" do
    handle = ProgramRunner.new_handle()
    assert {:ok, %{status: :completed}} = ProgramRunner.run(handle, "text(1)", [], [])

    assert {:error, "program handle has already started"} =
             ProgramRunner.run(handle, "text(2)", [], [])
  end

  test "owner exit terminates native execution and releases its slot" do
    owner = spawn(fn -> ProgramRunner.run("for (;;) {}", [], []) end)
    assert wait_for(fn -> ProgramRunner.active_runs() == 1 end)
    Process.exit(owner, :kill)
    assert wait_for(fn -> ProgramRunner.active_runs() == 0 end)
  end

  test "an owner that exits before admission leaves its handle cancelled" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(owner)
    handle = ProgramRunner.new_handle(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:ok, %{error_code: "program_cancelled"}} =
             ProgramRunner.run(handle, "for (;;) {}", [], [])

    assert ProgramRunner.active_runs() == 0
  end

  test "a handle created for a dead owner cannot execute" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    handle = ProgramRunner.new_handle(owner)

    assert {:ok, %{error_code: "program_cancelled"}} =
             ProgramRunner.run(handle, "for (;;) {}", [], [])

    assert ProgramRunner.active_runs() == 0
  end

  test "full admission returns busy synchronously without a scheduler message" do
    handles =
      for _ <- 1..4 do
        handle = ProgramRunner.new_handle()
        assert {:ok, ^handle} = ProgramRunner.start(handle, "for (;;) {}", [], [])
        handle
      end

    try do
      extra = ProgramRunner.new_handle()

      assert {:error, {:program_runner_busy, %{error_code: "program_runtime_busy"}}} =
               ProgramRunner.start(extra, "text(1)", [], [])

      refute_receive {:program_runner, ^extra, _}, 20
    after
      Enum.each(handles, &ProgramRunner.cancel/1)
      Enum.each(handles, &ProgramRunner.await/1)
    end

    assert ProgramRunner.active_runs() == 0
  end

  test "native programs leave the single dirty CPU scheduler available to AuthZ" do
    original = :erlang.system_flag(:dirty_cpu_schedulers_online, 1)
    handles = for _ <- 1..4, do: ProgramRunner.new_handle()

    try do
      Enum.each(handles, fn handle ->
        assert {:ok, ^handle} =
                 ProgramRunner.start(handle, "for (;;) {}", [], [], timeout_ms: 2_000)
      end)

      request = %{
        principal: %{uid: "alice", type: "human", status: "active"},
        staticGroupIDs: [],
        computedGroups: [],
        grants: [],
        resource: "workspace:default",
        action: "read",
        context: %{}
      }

      # Load the NIF and its evaluator before the latency assertion.
      assert %{"status" => "deny"} = Ankole.Kernel.authz_authorize(request)
      {elapsed, decision} = :timer.tc(fn -> Ankole.Kernel.authz_authorize(request) end)
      assert %{"status" => "deny"} = decision
      assert elapsed < 20_000
    after
      :erlang.system_flag(:dirty_cpu_schedulers_online, original)
      Enum.each(handles, &ProgramRunner.cancel/1)
      Enum.each(handles, &ProgramRunner.await/1)
    end
  end

  defp wait_for(check, attempts \\ 200)
  defp wait_for(_check, 0), do: false

  defp wait_for(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      wait_for(check, attempts - 1)
    end
  end
end
