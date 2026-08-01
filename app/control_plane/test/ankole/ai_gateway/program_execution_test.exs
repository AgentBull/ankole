defmodule Ankole.AIGateway.ProgramExecutionTest do
  use ExUnit.Case, async: false

  alias Ankole.AIGateway.ProgramExecution

  defp job(call_id, code \\ ~s|text("ok");|) do
    %{call_id: call_id, code: code, binding_names: [], memo: []}
  end

  defp assert_completed(handle, call_id) do
    assert_receive {:program_execution, ref,
                    [%{call_id: ^call_id, outcome: %{status: :completed}}]},
                   1_000

    assert ref == handle.ref
  end

  test "an all-preflight batch does not require native task capacity" do
    outcome = %{
      status: :failed,
      output: [],
      pending_calls: [],
      error: "history limit exceeded",
      error_code: "program_admission_failed"
    }

    assert {:complete, [%{call_id: "prog_preflight", outcome: ^outcome}]} =
             ProgramExecution.start(
               self(),
               [%{call_id: "prog_preflight", preflight_outcome: outcome}],
               supervisor: :supervisor_that_does_not_exist
             )
  end

  test "an admitted native task carries one monitored run id" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    assert {:ok, handle} = ProgramExecution.start(self(), [job("prog_1")], supervisor: supervisor)
    assert is_binary(handle.run_id)
    refute Map.has_key?(handle, :lease)
    refute Map.has_key?(handle, :guardian)

    assert_receive {:program_execution, ref,
                    [
                      %{
                        call_id: "prog_1",
                        outcome: %{status: :completed, output: [%{kind: "text", value: "ok"}]}
                      }
                    ]},
                   1_000

    assert ref == handle.ref
  end

  test "a missing task supervisor returns unavailable without consuming task capacity" do
    for _attempt <- 1..32 do
      assert {:error, {:program_runtime_unavailable, _reason}} =
               ProgramExecution.start(self(), [job("prog_missing")],
                 supervisor: :program_execution_missing_supervisor
               )
    end

    {:ok, supervisor} = Task.Supervisor.start_link()

    assert {:ok, handle} =
             ProgramExecution.start(self(), [job("prog_missing")], supervisor: supervisor)

    assert_completed(handle, "prog_missing")
  end

  test "a dead task supervisor returns unavailable instead of exiting the caller" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Process.unlink(supervisor)
    supervisor_monitor = Process.monitor(supervisor)
    Process.exit(supervisor, :kill)
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, :killed}, 1_000

    assert {:error, {:program_runtime_unavailable, _reason}} =
             ProgramExecution.start(self(), [job("prog_dead")], supervisor: supervisor)
  end

  test "explicit cancellation signals the native run before it kills the task" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    assert {:ok, handle} =
             ProgramExecution.start(self(), [job("prog_loop", "for (;;) {}")],
               supervisor: supervisor
             )

    Process.sleep(50)
    cancelled_at = System.monotonic_time(:millisecond)
    assert :ok = ProgramExecution.cancel(handle)
    assert_receive {:DOWN, monitor, :process, pid, :killed}, 1_000
    assert monitor == handle.monitor
    assert pid == handle.pid
    assert System.monotonic_time(:millisecond) - cancelled_at < 1_000

    assert {:ok, next_handle} =
             ProgramExecution.start(self(), [job("prog_next", ~s|text("next");|)],
               supervisor: supervisor
             )

    assert_completed(next_handle, "prog_next")
  end

  test "owner death does not add a second task guardian" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    test_pid = self()
    owner = spawn(fn -> Process.sleep(:infinity) end)

    runner = fn _code, _bindings, _memo ->
      send(test_pid, {:program_runner_started, self()})

      receive do
        :finish -> {:ok, %{status: :completed, output: [], pending_calls: []}}
      end
    end

    assert {:ok, handle} =
             ProgramExecution.start(owner, [job("prog_orphan")],
               supervisor: supervisor,
               runner: runner
             )

    assert_receive {:program_runner_started, task_pid}, 1_000
    assert task_pid == handle.pid
    Process.exit(owner, :kill)
    refute_receive {:DOWN, _monitor, :process, ^task_pid, _reason}, 50
    send(task_pid, :finish)

    assert_receive {:DOWN, monitor, :process, pid, :normal}, 1_000
    assert monitor == handle.monitor
    assert pid == handle.pid
  end

  test "an already dead owner is rejected before native admission" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    owner = spawn(fn -> Process.sleep(:infinity) end)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000

    for _attempt <- 1..32 do
      assert {:error, :program_owner_unavailable} =
               ProgramExecution.start(owner, [job("prog_dead_owner")], supervisor: supervisor)
    end

    assert {:ok, handle} =
             ProgramExecution.start(self(), [job("prog_live_owner")], supervisor: supervisor)

    assert_completed(handle, "prog_live_owner")
  end
end
