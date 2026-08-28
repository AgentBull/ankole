defmodule Ankole.Workflow.RunServerTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Workflow
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  defmodule BlockingRunner do
    def run(_run_id, _source, _tools, _memo, _options) do
      owner = Process.whereis(:workflow_run_server_test_runner_owner)
      send(owner, {:blocking_runner_started, self()})

      receive do
        :finish -> {:error, :unexpected_finish}
      end
    end

    def cancel(run_id) do
      send(
        Process.whereis(:workflow_run_server_test_runner_owner),
        {:blocking_runner_cancelled, run_id}
      )

      :ok
    end
  end

  setup do
    if is_nil(Process.whereis(Ankole.Workflow.Supervisor)) do
      start_supervised!(Ankole.Workflow.Supervisor)
    end

    :ok
  end

  test "pending replay inserts durable calls and idempotent task events with hard limits" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    arguments = %{
      "prompt" => "Review the release.",
      "label" => "review",
      "schema" => %{"type" => "boolean"}
    }

    runner = queue_runner(self(), [pending_outcome([pending_call(arguments)])])

    assert :ok = RunServer.poke(run.id, runner: runner)

    assert_receive {:program_run, run_id, source, tools, [], options}, 1_000
    assert run_id == "wf-#{run.id}"
    assert source =~ "const args = {};"
    assert tools == [%{"namespace" => nil, "name" => "agent", "global_name" => "agent"}]

    assert options == [
             max_pending_calls: 1_024,
             max_pending_bytes: 8 * 1_024 * 1_024,
             max_memo_bytes: 8 * 1_024 * 1_024
           ]

    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)
    assert call.arguments == arguments
    assert call.status == "queued"

    event =
      Repo.get_by!(ActorEvent,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{call.id}:dispatch"
      )

    assert event.session_id == Workflow.task_session_id(call.id)
    assert event.type == "workflow.task.dispatch"
    assert event.signal_channel_id == nil
    assert event.payload["data"]["call_id"] == call.id
    assert event.payload["data"]["schema"] == %{"type" => "boolean"}
  end

  test "completed replay stores joined output and appends one owner wakeup" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    runner = queue_runner(self(), [completed_outcome(["hello", " world"])])

    assert :ok = RunServer.poke(run.id, runner: runner)
    assert_receive {:program_run, _, _, _, _, _}, 1_000

    completed = wait_for(fn -> terminal_run(run.id, "completed") end)
    assert completed.result_text == "hello world"

    wakeup_source_event_id = "workflow:#{run.id}:completed"

    wakeups =
      Repo.all(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.source_event_id == ^wakeup_source_event_id
        )
      )

    assert [wakeup] = wakeups
    assert wakeup.session_id == run.owner_session_id
    assert wakeup.type == "workflow.run.completed"
    assert wakeup.payload["data"]["result_preview"] == "hello world"

    assert wakeup.payload["data"]["counts"] == %{
             "total" => 0,
             "succeeded" => 0,
             "failed" => 0
           }

    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
  end

  test "invalid oversized pending arguments fail once and wake the owner once" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    arguments = %{"prompt" => String.duplicate("x", 8_180)}
    assert byte_size(Torque.encode!(arguments)) == 8_193

    runner = queue_runner(self(), [pending_outcome([pending_call(arguments)])])

    assert :ok = RunServer.poke(run.id, runner: runner)
    assert_receive {:program_run, _, _, _, _, _}, 1_000

    failed = wait_for(fn -> terminal_run(run.id, "failed") end)
    assert failed.error["code"] == "workflow_agent_call_invalid"
    assert Repo.aggregate(AgentCall, :count) == 0

    wakeup_source_event_id = "workflow:#{run.id}:failed"

    assert [wakeup] =
             Repo.all(
               from(event in ActorEvent,
                 where: event.source_event_id == ^wakeup_source_event_id
               )
             )

    assert wakeup.type == "workflow.run.failed"
    refute_receive {:program_run, _, _, _, _, _}, 100
  end

  test "runtime busy retries without failing the run" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    runner =
      queue_runner(self(), [
        failed_outcome("program_runtime_busy", "Runtime is busy."),
        completed_outcome(["done"])
      ])

    assert :ok = RunServer.poke(run.id, runner: runner, runtime_busy_retry_ms: 20)
    assert_receive {:program_run, _, _, _, _, _}, 1_000
    assert_receive {:program_run, _, _, _, _, _}, 1_000

    assert %Run{status: "completed", result_text: "done"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)
  end

  test "a duplicate program run ID retries without a durable failure" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    runner =
      queue_runner(self(), [
        failed_outcome("program_run_id_conflict", "The registered run is still active."),
        completed_outcome(["winner completed"])
      ])

    assert :ok = RunServer.poke(run.id, runner: runner, runtime_busy_retry_ms: 20)
    assert_receive {:program_run, _, _, _, _, _}, 1_000
    assert_receive {:program_run, _, _, _, _, _}, 1_000

    assert %Run{status: "completed", result_text: "winner completed"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)

    failed_source_event_id = "workflow:#{run.id}:failed"

    refute Repo.exists?(
             from(event in ActorEvent,
               where: event.source_event_id == ^failed_source_event_id
             )
           )
  end

  test "pokes during replay coalesce into one dirty replay" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    parent = self()
    counter = :atomics.new(1, signed: false)
    arguments = %{"prompt" => "Inspect."}

    runner = fn run_id, source, tools, memo, options ->
      invocation = :atomics.add_get(counter, 1, 1)
      send(parent, {:program_run, invocation, self(), run_id, source, tools, memo, options})

      if invocation == 1 do
        receive do
          :release -> :ok
        end
      end

      pending_outcome([pending_call(arguments)])
    end

    assert :ok = RunServer.poke(run.id, runner: runner)
    assert_receive {:program_run, 1, task, _, _, _, _, _}, 1_000

    assert :ok = RunServer.poke(run.id)
    assert :ok = RunServer.poke(run.id)
    send(task, :release)

    assert_receive {:program_run, 2, _, _, _, _, _, _}, 1_000
    refute_receive {:program_run, 3, _, _, _, _, _, _}, 150
    assert :atomics.get(counter, 1) == 2
    assert Repo.aggregate(AgentCall, :count) == 1
  end

  test "a transaction snapshot fence rejects stale pending before its poke arrives" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    first_arguments = %{"prompt" => "Finish the first task."}
    stale_arguments = %{"prompt" => "This stale task must not be inserted."}

    assert {:ok, %{new_calls: [call]}} =
             Workflow.commit_replay_pending(run.id, [pending_call(first_arguments)], 0)

    assert {:ok, %{call: running}} =
             Workflow.claim_task_in_tx(Repo, call.id, agent.uid, 8)

    parent = self()
    counter = :atomics.new(1, signed: false)

    runner = fn _run_id, _source, _tools, memo, _options ->
      invocation = :atomics.add_get(counter, 1, 1)
      send(parent, {:snapshot_replay, invocation, self(), memo})

      case invocation do
        1 ->
          receive do
            :release -> :ok
          end

          pending_outcome([
            pending_call(first_arguments),
            pending_call(stale_arguments)
          ])

        2 ->
          completed_outcome(["fresh result"])
      end
    end

    assert :ok = RunServer.poke(run.id, runner: runner)
    assert_receive {:snapshot_replay, 1, replay_task, []}, 1_000

    assert {:ok, %{accepted: true, call: %AgentCall{status: "succeeded"}}} =
             Workflow.submit_result(
               running.id,
               agent.uid,
               Workflow.task_session_id(running.id),
               %{"ok" => true, "value" => "finished"}
             )

    send(replay_task, :release)

    assert_receive {:snapshot_replay, 2, _task, [memo]}, 1_000
    assert memo["arguments"] == first_arguments
    assert memo["output"] == %{"ok" => true, "value" => "finished"}

    assert %Run{status: "completed", result_text: "fresh result"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)

    assert Repo.aggregate(from(stored in AgentCall, where: stored.run_id == ^run.id), :count) == 1
    refute Repo.get_by(AgentCall, run_id: run.id, call_seq: 1)

    assert Repo.aggregate(
             from(event in ActorEvent,
               where: event.agent_uid == ^agent.uid,
               where: event.type == "workflow.task.dispatch"
             ),
             :count
           ) == 1
  end

  test "a transaction snapshot fence rejects stale terminal outcomes" do
    %{principal: agent} = agent_fixture()

    stale_outcomes = [
      {:completed, completed_outcome(["stale completion"])},
      {:failed, failed_outcome("stale_failure", "This failure came from an old memo.")}
    ]

    for {kind, stale_outcome} <- stale_outcomes do
      run = run_fixture(agent.uid)
      arguments = %{"prompt" => "Advance the memo before #{kind}."}

      assert {:ok, %{new_calls: [call]}} =
               Workflow.commit_replay_pending(run.id, [pending_call(arguments)], 0)

      assert {:ok, %{call: running}} =
               Workflow.claim_task_in_tx(Repo, call.id, agent.uid, 8)

      parent = self()
      counter = :atomics.new(1, signed: false)

      runner = fn _run_id, _source, _tools, memo, _options ->
        invocation = :atomics.add_get(counter, 1, 1)
        send(parent, {:terminal_snapshot_replay, run.id, invocation, self(), memo})

        case invocation do
          1 ->
            receive do
              :release -> stale_outcome
            end

          2 ->
            completed_outcome(["fresh #{kind}"])
        end
      end

      assert :ok = RunServer.poke(run.id, runner: runner)

      assert_receive {:terminal_snapshot_replay, run_id, 1, replay_task, []}, 1_000
      assert run_id == run.id

      assert {:ok, %{accepted: true}} =
               Workflow.submit_result(
                 running.id,
                 agent.uid,
                 Workflow.task_session_id(running.id),
                 %{"ok" => true, "value" => "terminal"}
               )

      send(replay_task, :release)

      assert_receive {:terminal_snapshot_replay, ^run_id, 2, _task, [memo]}, 1_000
      assert memo["output"] == %{"ok" => true, "value" => "terminal"}

      assert %Run{status: "completed", result_text: result_text} =
               wait_for(fn -> terminal_run(run.id, "completed") end)

      assert result_text == "fresh #{kind}"

      failed_source_event_id = "workflow:#{run.id}:failed"

      refute Repo.exists?(
               from(event in ActorEvent,
                 where: event.source_event_id == ^failed_source_event_id
               )
             )
    end
  end

  test "an abnormal replay task DOWN retries safely" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    parent = self()
    counter = :atomics.new(1, signed: false)

    runner = fn _run_id, _source, _tools, _memo, _options ->
      invocation = :atomics.add_get(counter, 1, 1)
      send(parent, {:runner_started, invocation, self()})

      if invocation == 1 do
        receive do
          :never -> :ok
        end
      end

      completed_outcome(["recovered"])
    end

    assert :ok = RunServer.poke(run.id, runner: runner, runtime_busy_retry_ms: 20)
    assert_receive {:runner_started, 1, task}, 1_000
    Process.exit(task, :kill)
    assert_receive {:runner_started, 2, _task}, 1_000

    assert %Run{status: "completed", result_text: "recovered"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)
  end

  test "a replacement server rebuilds its memo from PostgreSQL" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    arguments = %{"prompt" => "Persist this call."}
    first_runner = queue_runner(self(), [pending_outcome([pending_call(arguments)])])

    assert :ok = RunServer.poke(run.id, runner: first_runner)
    assert_receive {:program_run, _, _, _, [], _}, 1_000
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)

    first_server = RunServer.whereis(run.id)
    monitor = Process.monitor(first_server)
    Process.exit(first_server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first_server, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)

    assert {:ok, %{call: running}} =
             Workflow.claim_task_in_tx(Repo, call.id, agent.uid, 8)

    assert {:ok, %{call: %AgentCall{status: "succeeded"}}} =
             Workflow.submit_result(
               running.id,
               agent.uid,
               Workflow.task_session_id(running.id),
               %{"ok" => true, "value" => "persisted"}
             )

    second_runner = queue_runner(self(), [completed_outcome(["rebuilt"])])
    assert :ok = RunServer.poke(run.id, runner: second_runner)

    assert_receive {:program_run, _, _, _, [memo], _}, 1_000
    assert memo["arguments"] == arguments
    assert memo["output"] == %{"ok" => true, "value" => "persisted"}

    assert %Run{status: "completed", result_text: "rebuilt"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)
  end

  test "watchdog requeues a stale running task and replays it" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    arguments = %{"prompt" => "Inspect stale work."}

    runner =
      queue_runner(self(), [
        pending_outcome([pending_call(arguments)]),
        pending_outcome([pending_call(arguments)])
      ])

    assert :ok =
             RunServer.poke(run.id,
               runner: runner,
               watchdog_interval_ms: 20,
               stale_after_seconds: 1
             )

    assert_receive {:program_run, _, _, _, _, _}, 1_000
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)

    assert {:ok, %{call: running}} =
             Workflow.claim_task_in_tx(Repo, call.id, agent.uid, 8)

    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)

    {1, _rows} =
      AgentCall
      |> where([stored], stored.id == ^running.id)
      |> Repo.update_all(set: [updated_at: stale_at])

    assert_receive {:program_run, _, _, _, _, _}, 1_000

    requeued = wait_for(fn -> Repo.get(AgentCall, call.id) |> queued_call() end)
    assert requeued.attempts == 1
    assert requeued.error["code"] == "workflow_task_stale"

    assert {:ok, %{run: %Run{status: "cancelled"}}} =
             RunServer.cancel(run.id, agent.uid)

    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
  end

  test "watchdog defers stale reconciliation while a replay snapshot is active" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    arguments = %{"prompt" => "Inspect a stale terminal attempt."}
    parent = self()
    counter = :atomics.new(1, signed: false)

    runner = fn _run_id, _source, _tools, memo, _options ->
      invocation = :atomics.add_get(counter, 1, 1)
      send(parent, {:watchdog_snapshot_replay, invocation, self(), memo})

      case invocation do
        1 ->
          pending_outcome([pending_call(arguments)])

        2 ->
          receive do
            :release -> :ok
          end

          pending_outcome([pending_call(arguments)])

        3 ->
          completed_outcome(["reconciled safely"])
      end
    end

    assert :ok =
             RunServer.poke(run.id,
               runner: runner,
               watchdog_interval_ms: 200,
               stale_after_seconds: 1
             )

    assert_receive {:watchdog_snapshot_replay, 1, _task, []}, 1_000
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)

    assert {:ok, %{call: running}} =
             Workflow.claim_task_in_tx(Repo, call.id, agent.uid, 8)

    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)

    {1, _rows} =
      AgentCall
      |> where([stored], stored.id == ^running.id)
      |> Repo.update_all(set: [attempts: 3, updated_at: stale_at])

    assert :ok = RunServer.poke(run.id)
    assert_receive {:watchdog_snapshot_replay, 2, replay_task, []}, 1_000

    Process.sleep(250)
    assert %AgentCall{status: "running", attempts: 3} = Repo.get!(AgentCall, call.id)
    assert %Run{status: "running"} = Repo.get!(Run, run.id)

    send(replay_task, :release)

    assert_receive {:watchdog_snapshot_replay, 3, _task, [memo]}, 1_000
    assert memo["output"]["code"] == "workflow_task_stale"

    assert %Run{status: "completed", result_text: "reconciled safely"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)

    assert %AgentCall{status: "failed", attempts: 3} = Repo.get!(AgentCall, call.id)
  end

  test "cancel terminates an in-flight replay and calls the native cancellation seam" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    true = Process.register(self(), :workflow_run_server_test_runner_owner)

    assert :ok = RunServer.poke(run.id, runner: BlockingRunner)
    assert_receive {:blocking_runner_started, task}, 1_000
    monitor = Process.monitor(task)

    assert {:ok, %{run: %Run{status: "cancelled"}}} =
             RunServer.cancel(run.id, agent.uid)

    assert_receive {:blocking_runner_cancelled, "wf-" <> _run_id}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
  end

  test "an unauthorized creating cancel cannot stop an active replay" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    run = run_fixture(agent.uid)
    parent = self()

    runner = fn _run_id, _source, _tools, _memo, _options ->
      send(parent, {:authorized_replay_started, self()})

      receive do
        :release -> completed_outcome(["authorized replay completed"])
      end
    end

    assert :ok = RunServer.poke(run.id, runner: runner)
    assert_receive {:authorized_replay_started, replay_task}, 1_000
    replay_monitor = Process.monitor(replay_task)
    server = RunServer.whereis(run.id)

    assert {:error, :workflow_not_found} = RunServer.cancel(run.id, other_agent.uid)

    assert Process.alive?(server)
    refute_receive {:DOWN, ^replay_monitor, :process, ^replay_task, _reason}, 50
    send(replay_task, :release)

    assert %Run{status: "completed", result_text: "authorized replay completed"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)
  end

  test "cancel survives a server that completes and stops before the call is handled" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    parent = self()

    runner = fn _run_id, _source, _tools, _memo, _options ->
      send(parent, {:terminal_race_replay_started, self()})

      receive do
        :release -> completed_outcome(["completed before cancel"])
      end
    end

    assert :ok = RunServer.poke(run.id, runner: runner)
    assert_receive {:terminal_race_replay_started, replay_task}, 1_000
    server = RunServer.whereis(run.id)
    :ok = :sys.suspend(server)

    on_exit(fn ->
      if Process.alive?(server) do
        try do
          :sys.resume(server)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    replay_monitor = Process.monitor(replay_task)
    send(replay_task, :release)
    assert_receive {:DOWN, ^replay_monitor, :process, ^replay_task, :normal}, 1_000

    cancel_task =
      Task.async(fn -> RunServer.cancel(run.id, agent.uid, runner: runner) end)

    assert wait_for(fn -> replay_and_cancel_call_queued?(server) end)
    :ok = :sys.resume(server)

    assert {:ok, %{run: %Run{status: "completed", result_text: "completed before cancel"}}} =
             Task.await(cancel_task, 2_000)

    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)

    completed_source_event_id = "workflow:#{run.id}:completed"

    assert Repo.aggregate(
             from(event in ActorEvent,
               where: event.source_event_id == ^completed_source_event_id
             ),
             :count
           ) == 1
  end

  test "a stale wake for a missing run stops its temporary server" do
    missing_run_id = 9_007_199_254_740_000
    runner = queue_runner(self(), [completed_outcome(["must not run"])])

    assert :ok = RunServer.poke(missing_run_id, runner: runner, runtime_busy_retry_ms: 20)
    wait_for(fn -> is_nil(RunServer.whereis(missing_run_id)) end)
    refute_receive {:program_run, _, _, _, _, _}, 100
  end

  test "failed cancel cleans a missing server but drives an authorized durable run" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    run = run_fixture(agent.uid)
    missing_run_id = 9_007_199_254_740_001
    parent = self()

    assert {:error, :workflow_not_found} =
             RunServer.cancel(missing_run_id, agent.uid)

    wait_for(fn -> is_nil(RunServer.whereis(missing_run_id)) end)

    runner = fn _run_id, _source, _tools, _memo, _options ->
      send(parent, {:hidden_cancel_replay_started, self()})

      receive do
        :release -> completed_outcome(["durable run survived"])
      end
    end

    assert {:error, :workflow_not_found} =
             RunServer.cancel(run.id, other_agent.uid, runner: runner)

    assert_receive {:hidden_cancel_replay_started, replay_task}, 1_000
    legitimate_server = RunServer.whereis(run.id)
    assert Process.alive?(legitimate_server)

    assert {:error, :workflow_not_found} = RunServer.cancel(run.id, other_agent.uid)
    assert Process.alive?(legitimate_server)

    send(replay_task, :release)

    assert %Run{status: "completed", result_text: "durable run survived"} =
             wait_for(fn -> terminal_run(run.id, "completed") end)

    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
  end

  test "cancel is durable before running task stop cleanup" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    assert {:ok, %{new_calls: [running, queued]}} =
             Workflow.commit_replay_pending(
               run.id,
               [
                 %{namespace: nil, name: "agent", arguments: %{"prompt" => "Run."}},
                 %{namespace: nil, name: "agent", arguments: %{"prompt" => "Wait."}}
               ],
               0
             )

    assert {:ok, %{call: running}} =
             Workflow.claim_task_in_tx(Repo, running.id, agent.uid, 8)

    assert {:ok, result} = Workflow.cancel(run.id, agent.uid)
    assert result.run.status == "cancelled"
    assert %DateTime{} = result.run.cleanup_completed_at
    assert result.cleanup_errors == []
    assert result.running_session_ids == [Workflow.task_session_id(running.id)]
    assert Repo.get!(AgentCall, queued.id).status == "cancelled"
    assert Repo.get!(AgentCall, running.id).status == "cancelled"

    stop =
      Repo.get_by!(ActorEvent,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{running.id}:stop"
      )

    assert stop.session_id == Workflow.task_session_id(running.id)
    assert stop.type == "command.stop"
    assert stop.signal_channel_id == nil
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
  end

  defp run_fixture(agent_uid) do
    Repo.insert!(
      Run.creation_changeset(%Run{}, %{
        agent_uid: agent_uid,
        owner_session_id: "owner-#{System.unique_integer([:positive])}",
        reply_route: %{"binding_name" => "bot"},
        source_tool_call_id: "tool-#{System.unique_integer([:positive])}",
        title: "Workflow",
        script: "return 'done';",
        args: %{},
        status: "running",
        concurrency: 8,
        max_agent_calls: 256,
        error: %{}
      })
    )
  end

  defp queue_runner(parent, outcomes) do
    {:ok, queue} = Agent.start_link(fn -> outcomes end)

    fn run_id, source, tools, memo, options ->
      send(parent, {:program_run, run_id, source, tools, memo, options})

      Agent.get_and_update(queue, fn
        [outcome | remaining] -> {outcome, remaining}
        [] -> {failed_outcome("unexpected_replay", "No queued test outcome."), []}
      end)
    end
  end

  defp pending_call(arguments), do: %{namespace: nil, name: "agent", arguments: arguments}

  defp pending_outcome(pending_calls) do
    {:ok,
     %{
       status: :pending,
       output: [],
       pending_calls: pending_calls,
       error: nil,
       error_code: nil
     }}
  end

  defp completed_outcome(values) do
    {:ok,
     %{
       status: :completed,
       output: Enum.map(values, &%{kind: "text", value: &1}),
       pending_calls: [],
       error: nil,
       error_code: nil
     }}
  end

  defp failed_outcome(code, summary) do
    {:ok,
     %{
       status: :failed,
       output: [],
       pending_calls: [],
       error: summary,
       error_code: code
     }}
  end

  defp terminal_run(run_id, status) do
    case Repo.get(Run, run_id) do
      %Run{status: ^status, cleanup_completed_at: %DateTime{}} = run -> run
      _run -> nil
    end
  end

  defp queued_call(%AgentCall{status: "queued"} = call), do: call
  defp queued_call(_call), do: nil

  defp replay_and_cancel_call_queued?(server) do
    case Process.info(server, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, &match?({:workflow_replay_finished, _ref, _result}, &1)) and
          Enum.any?(messages, &match?({:"$gen_call", _from, {:cancel, _agent_uid}}, &1))

      nil ->
        false
    end
  end

  defp wait_for(fun, attempts \\ 200)

  defp wait_for(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_for(fun, attempts - 1)

      false ->
        Process.sleep(10)
        wait_for(fun, attempts - 1)

      result ->
        result
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition did not become true")
end
