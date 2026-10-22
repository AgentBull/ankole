defmodule Ankole.Workflow.RunServerTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.Signals.Signal
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
    assert is_reference(run_id)
    assert source =~ "const args = {};"
    assert tools == [%{"namespace" => nil, "name" => "agent", "global_name" => "agent"}]

    assert options == [
             max_pending_calls: 1_024,
             max_pending_bytes: 8 * 1_024 * 1_024,
             max_memo_bytes: 8 * 1_024 * 1_024
           ]

    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)
    assert call.arguments == arguments
    assert call.status == :queued

    event =
      Repo.get_by!(Signal,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{call.id}:dispatch"
      )

    assert event.session_id == Workflow.task_session_id(call.id)
    assert event.type == "workflow.task.dispatch"
    assert event.conversation_id == nil
    assert event.data["call_id"] == call.id
    assert event.data["schema"] == %{"type" => "boolean"}
  end

  test "completed replay stores joined output and appends one owner wakeup" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    runner = queue_runner(self(), [completed_outcome(["hello", " world"])])

    assert :ok = RunServer.poke(run.id, runner: runner)
    assert_receive {:program_run, _, _, _, _, _}, 1_000

    completed = wait_for(fn -> terminal_run(run.id, :completed) end)
    assert completed.result_text == "hello world"

    wakeup_source_event_id = "workflow:#{run.id}:completed"

    wakeups =
      Repo.all(
        from(event in Signal,
          where: event.agent_uid == ^agent.uid,
          where: event.source_event_id == ^wakeup_source_event_id
        )
      )

    assert [wakeup] = wakeups
    assert wakeup.session_id == run.owner_session_id
    assert wakeup.type == "workflow.run.completed"
    assert wakeup.data["result_preview"] == "hello world"

    assert wakeup.data["counts"] == %{
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

    failed = wait_for(fn -> terminal_run(run.id, :failed) end)
    assert failed.error["code"] == "workflow_agent_call_invalid"
    assert Repo.aggregate(AgentCall, :count) == 0

    wakeup_source_event_id = "workflow:#{run.id}:failed"

    assert [wakeup] =
             Repo.all(
               from(event in Signal,
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

    assert %Run{status: :completed, result_text: "done"} =
             wait_for(fn -> terminal_run(run.id, :completed) end)
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
             Repo.transact(fn repo ->
               Workflow.TaskLifecycle.claim_task_in_tx(repo, call.id, agent.uid, 8)
             end)

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

    assert {:ok, %{accepted: true, call: %AgentCall{status: :succeeded}}} =
             Ankole.Repo.transact(fn repo ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 repo,
                 running.id,
                 agent.uid,
                 Workflow.task_session_id(running.id),
                 %{"ok" => true, "value" => "finished"}
               )
             end)

    send(replay_task, :release)

    assert_receive {:snapshot_replay, 2, _task, [memo]}, 1_000
    assert memo["arguments"] == first_arguments
    assert memo["output"] == %{"ok" => true, "value" => "finished"}

    assert %Run{status: :completed, result_text: "fresh result"} =
             wait_for(fn -> terminal_run(run.id, :completed) end)

    assert Repo.aggregate(from(stored in AgentCall, where: stored.run_id == ^run.id), :count) == 1
    refute Repo.get_by(AgentCall, run_id: run.id, call_seq: 1)

    assert Repo.aggregate(
             from(event in Signal,
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
               Repo.transact(fn repo ->
                 Workflow.TaskLifecycle.claim_task_in_tx(repo, call.id, agent.uid, 8)
               end)

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
               Ankole.Repo.transact(fn repo ->
                 Workflow.TaskLifecycle.submit_result_in_tx(
                   repo,
                   running.id,
                   agent.uid,
                   Workflow.task_session_id(running.id),
                   %{"ok" => true, "value" => "terminal"}
                 )
               end)

      send(replay_task, :release)

      assert_receive {:terminal_snapshot_replay, ^run_id, 2, _task, [memo]}, 1_000
      assert memo["output"] == %{"ok" => true, "value" => "terminal"}

      assert %Run{status: :completed, result_text: result_text} =
               wait_for(fn -> terminal_run(run.id, :completed) end)

      assert result_text == "fresh #{kind}"

      failed_source_event_id = "workflow:#{run.id}:failed"

      refute Repo.exists?(
               from(event in Signal,
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

    assert %Run{status: :completed, result_text: "recovered"} =
             wait_for(fn -> terminal_run(run.id, :completed) end)
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
    # Shared Sandbox reads can see an uncommitted task row. The state reply
    # waits for the replay commit and its dispatch before this crash fixture.
    assert is_nil(:sys.get_state(first_server).replay)
    monitor = Process.monitor(first_server)
    Process.exit(first_server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first_server, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)

    assert {:ok, %{call: running}} =
             Repo.transact(fn repo ->
               Workflow.TaskLifecycle.claim_task_in_tx(repo, call.id, agent.uid, 8)
             end)

    assert {:ok, %{call: %AgentCall{status: :succeeded}}} =
             Ankole.Repo.transact(fn repo ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 repo,
                 running.id,
                 agent.uid,
                 Workflow.task_session_id(running.id),
                 %{"ok" => true, "value" => "persisted"}
               )
             end)

    second_runner = queue_runner(self(), [completed_outcome(["rebuilt"])])
    assert :ok = RunServer.poke(run.id, runner: second_runner)

    assert_receive {:program_run, _, _, _, [memo], _}, 1_000
    assert memo["arguments"] == arguments
    assert memo["output"] == %{"ok" => true, "value" => "persisted"}

    assert %Run{status: :completed, result_text: "rebuilt"} =
             wait_for(fn -> terminal_run(run.id, :completed) end)
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
             Repo.transact(fn repo ->
               Workflow.TaskLifecycle.claim_task_in_tx(repo, call.id, agent.uid, 8)
             end)

    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)

    {1, _rows} =
      AgentCall
      |> where([stored], stored.id == ^running.id)
      |> Repo.update_all(set: [updated_at: stale_at, progress_at: stale_at])

    assert_receive {:program_run, _, _, _, _, _}, 1_000

    requeued = wait_for(fn -> Repo.get(AgentCall, call.id) |> queued_call() end)
    assert requeued.attempts == 1
    assert requeued.error["code"] == "workflow_task_stale"

    assert {:ok, %{run: %Run{status: :cancelled}}} =
             cancel_workflow(run.id, agent.uid)

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
             Repo.transact(fn repo ->
               Workflow.TaskLifecycle.claim_task_in_tx(repo, call.id, agent.uid, 8)
             end)

    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -5, :second)

    {1, _rows} =
      AgentCall
      |> where([stored], stored.id == ^running.id)
      |> Repo.update_all(set: [attempts: 3, updated_at: stale_at, progress_at: stale_at])

    assert :ok = RunServer.poke(run.id)
    assert_receive {:watchdog_snapshot_replay, 2, replay_task, []}, 1_000

    Process.sleep(250)
    assert %AgentCall{status: :running, attempts: 3} = Repo.get!(AgentCall, call.id)
    assert %Run{status: :running} = Repo.get!(Run, run.id)

    send(replay_task, :release)

    assert_receive {:watchdog_snapshot_replay, 3, _task, [memo]}, 1_000
    assert memo["output"]["code"] == "workflow_task_stale"

    assert %Run{status: :completed, result_text: "reconciled safely"} =
             wait_for(fn -> terminal_run(run.id, :completed) end)

    assert %AgentCall{status: :failed, attempts: 3} = Repo.get!(AgentCall, call.id)
  end

  test "cancel_workflow commits cancellation before stopping an in-flight replay" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    true = Process.register(self(), :workflow_run_server_test_runner_owner)

    assert :ok = RunServer.poke(run.id, runner: BlockingRunner)
    assert_receive {:blocking_runner_started, task}, 1_000
    monitor = Process.monitor(task)

    assert {:ok, %{run: %Run{status: :cancelled}}} =
             cancel_workflow(run.id, agent.uid)

    assert_receive {:blocking_runner_cancelled, handle}, 1_000
    assert is_reference(handle)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
  end

  test "cancel_workflow from another Agent cannot stop an active replay" do
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

    assert {:error, :workflow_not_found} = cancel_workflow(run.id, other_agent.uid)

    assert Process.alive?(server)
    refute_receive {:DOWN, ^replay_monitor, :process, ^replay_task, _reason}, 50
    send(replay_task, :release)

    assert %Run{status: :completed, result_text: "authorized replay completed"} =
             wait_for(fn -> terminal_run(run.id, :completed) end)
  end

  test "a queued replay result cannot revive cancellation committed by the real tool" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    parent = self()

    runner = fn _run_id, _source, _tools, _memo, _options ->
      send(parent, {:terminal_race_replay_started, self()})

      receive do
        :release -> completed_outcome(["late completion"])
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
    assert wait_for(fn -> queued_replay_result?(server) end)

    assert {:ok, %{run: %Run{status: :cancelled}}} = cancel_workflow(run.id, agent.uid)
    :ok = :sys.resume(server)
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)

    assert %Run{status: :cancelled, result_text: nil} = Repo.get!(Run, run.id)
    completed_source_event_id = "workflow:#{run.id}:completed"

    assert Repo.aggregate(
             from(event in Signal,
               where: event.source_event_id == ^completed_source_event_id
             ),
             :count
           ) == 0
  end

  test "cancellation before a replay owner starts cannot enter the runner" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    runner = queue_runner(self(), [completed_outcome(["must not run"])])

    assert {:ok, %{run: %Run{status: :cancelled}}} = cancel_workflow(run.id, agent.uid)
    assert RunServer.whereis(run.id) == nil
    assert :ok = RunServer.poke(run.id, runner: runner)
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
    refute_receive {:program_run, _, _, _, _, _}, 100
  end

  test "repeat cancellation stops a reconstructed owner without changing terminal facts" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    true = Process.register(self(), :workflow_run_server_test_runner_owner)

    assert {:ok, %{run: cancelled}} = cancel_workflow(run.id, agent.uid)
    assert RunServer.whereis(run.id) == nil
    assert {:ok, server} = RunServer.ensure_started(run.id, runner: BlockingRunner)
    monitor = Process.monitor(server)

    assert {:ok, %{run: repeated}} = cancel_workflow(run.id, agent.uid)
    assert repeated.status == :cancelled
    assert repeated.completed_at == cancelled.completed_at
    assert repeated.cleanup_completed_at == cancelled.cleanup_completed_at
    assert_receive {:blocking_runner_cancelled, handle}, 1_000
    assert is_reference(handle)
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 1_000
    assert RunServer.whereis(run.id) == nil
    refute_receive {:blocking_runner_started, _}, 50
  end

  test "a stale wake for a missing run stops its temporary server" do
    missing_run_id = 9_007_199_254_740_000
    runner = queue_runner(self(), [completed_outcome(["must not run"])])

    assert :ok = RunServer.poke(missing_run_id, runner: runner, runtime_busy_retry_ms: 20)
    wait_for(fn -> is_nil(RunServer.whereis(missing_run_id)) end)
    refute_receive {:program_run, _, _, _, _, _}, 100
  end

  test "a missing or unauthorized cancel_workflow never creates a replay owner" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    run = run_fixture(agent.uid)
    missing_run_id = 9_007_199_254_740_001

    assert {:error, :workflow_not_found} = cancel_workflow(missing_run_id, agent.uid)
    assert RunServer.whereis(missing_run_id) == nil
    assert {:error, :workflow_not_found} = cancel_workflow(run.id, other_agent.uid)
    assert RunServer.whereis(run.id) == nil
    assert Repo.get!(Run, run.id).status == :running
  end

  test "failed terminal cleanup remains recoverable after cancel_workflow stops replay" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    true = Process.register(self(), :workflow_run_server_test_runner_owner)

    assert {:ok, %{new_calls: [call]}} =
             Workflow.commit_replay_pending(run.id, [pending_call(%{"prompt" => "Run."})], 0)

    assert {:ok, %{call: call}} =
             Repo.transact(fn repo ->
               Workflow.TaskLifecycle.claim_task_in_tx(repo, call.id, agent.uid, 8)
             end)

    run
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(%{reply_route: %{}})
    |> Repo.update!()

    assert :ok = RunServer.poke(run.id, runner: BlockingRunner)
    assert_receive {:blocking_runner_started, replay_task}, 1_000
    monitor = Process.monitor(replay_task)

    assert {:ok, %{run: %Run{status: :cancelled, cleanup_completed_at: nil}, cleanup_errors: [_]}} =
             cancel_workflow(run.id, agent.uid)

    assert_receive {:blocking_runner_cancelled, handle}, 1_000
    assert is_reference(handle)
    assert_receive {:DOWN, ^monitor, :process, ^replay_task, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
    assert_enqueued(worker: Ankole.Workflow.Jobs.PokeRun, args: %{run_id: run.id})

    Repo.get!(Run, run.id)
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(%{reply_route: %{"binding_name" => "bot"}})
    |> Repo.update!()

    assert :ok = perform_job(Ankole.Sessions.Reconciler, %{})
    assert :ok = perform_job(Ankole.Workflow.Jobs.PokeRun, %{run_id: run.id})
    wait_for(fn -> terminal_run(run.id, :cancelled) end)

    assert Repo.get_by!(Signal, source_event_id: "workflow:call:#{call.id}:stop").type ==
             "command.stop"
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
             Repo.transact(fn repo ->
               Workflow.TaskLifecycle.claim_task_in_tx(repo, running.id, agent.uid, 8)
             end)

    assert {:ok, result} = cancel_workflow(run.id, agent.uid)
    assert result.run.status == :cancelled
    assert %DateTime{} = result.run.cleanup_completed_at
    assert result.cleanup_errors == []
    assert result.running_session_ids == [Workflow.task_session_id(running.id)]
    assert Repo.get!(AgentCall, queued.id).status == :cancelled
    assert Repo.get!(AgentCall, running.id).status == :cancelled

    stop =
      Repo.get_by!(Signal,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{running.id}:stop"
      )

    assert stop.session_id == Workflow.task_session_id(running.id)
    assert stop.type == "command.stop"
    assert stop.conversation_id == nil
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)
  end

  defp cancel_workflow(run_id, agent_uid) do
    result =
      Repo.transact(fn repo ->
        with {:ok, sessions, commit} <-
               Ankole.Sessions.Tools.Workflow.prepare_in_tx(
                 repo,
                 %{agent_uid: agent_uid, session_id: "cancel-caller-session"},
                 %{"name" => "cancel_workflow"},
                 %{"run_id" => run_id}
               ),
             :ok <- Ankole.Sessions.Queue.lock_sessions_in_tx(repo, sessions),
             {:ok, result, after_commit} <- commit.() do
          {:ok, {result, after_commit}}
        end
      end)

    case result do
      {:ok, {tool_result, [after_commit]}} ->
        assert tool_result.details["status"] == Atom.to_string(Repo.get!(Run, run_id).status)
        after_commit.()

      {:error, _reason} = error ->
        error
    end
  end

  defp run_fixture(agent_uid) do
    {:ok, run} =
      Repo.transact(fn ->
        Ankole.Ash.create(Run, :create_run, %{
          authorization_kind: "service",
          agent_uid: agent_uid,
          owner_session_id: "owner-#{System.unique_integer([:positive])}",
          reply_route: %{"binding_name" => "bot"},
          source_tool_call_id: "tool-#{System.unique_integer([:positive])}",
          title: "Workflow",
          script: "return 'done';",
          args: %{},
          concurrency: 8,
          max_agent_calls: 256,
          error: %{}
        })
      end)

    # Replay tests claim task rows themselves. Install the passive Driver
    # before dispatch so a real admission cannot consume those fixture rows.
    Ankole.SessionsCase.stub_workflow_drivers(run)
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

  defp queued_call(%AgentCall{status: :queued} = call), do: call
  defp queued_call(_call), do: nil

  defp queued_replay_result?(server) do
    case Process.info(server, :messages) do
      {:messages, messages} -> Enum.any?(messages, &match?({:workflow_replay_finished, _, _}, &1))
      nil -> false
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
