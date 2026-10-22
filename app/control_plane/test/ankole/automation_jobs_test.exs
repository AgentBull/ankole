defmodule Ankole.AutomationJobsTest do
  # Serial because cron creation reads `system.timezone` through the shared
  # AppConfigure ETS cache, which needs the shared sandbox connection.
  use Ankole.DataCase, async: false

  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.Settings
  alias Ankole.AgentWorkers.AgentWorker

  @now ~U[2026-07-30 09:00:00.000000Z]

  test "attempt fences reject stale completion and emission after infrastructure replay" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source, wake_on_failure: true)
    run = enqueue!(job, trigger_event("first"))

    assert_enqueued(worker: ExecuteRun, args: %{"automation_job_run_id" => run.id})
    assert run.status == :queued
    assert run.attempts == 0

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: first_attempt}} =
             AutomationJobs.start_attempt(run.id, now: @now)

    assert first_attempt.status == :running
    assert first_attempt.attempts == 1
    assert first_attempt.started_at == @now
    assert Ecto.UUID.cast(first_attempt.attempt_id) != :error

    assert {:ok, replayable} =
             AutomationJobs.infrastructure_failure(
               run.id,
               first_attempt.attempt_id,
               :socket_closed,
               :retry,
               now: DateTime.add(@now, 1, :second)
             )

    assert replayable.status == :queued
    assert replayable.attempt_id == nil
    assert replayable.attempts == 1

    assert {:error, :automation_job_attempt_not_active} =
             AutomationJobs.emit_event(
               agent.uid,
               run.id,
               first_attempt.attempt_id,
               %{"stale" => true}
             )

    assert {:ok, :stale} =
             AutomationJobs.finish_attempt(
               run.id,
               first_attempt.attempt_id,
               %{"status" => "succeeded"}
             )

    assert {:ok, %{run: second_attempt}} =
             AutomationJobs.start_attempt(run.id, now: DateTime.add(@now, 2, :second))

    assert second_attempt.attempts == 2
    assert second_attempt.started_at == DateTime.add(@now, 2, :second)
    refute second_attempt.attempt_id == first_attempt.attempt_id

    assert {:ok, emitted} =
             AutomationJobs.emit_event(
               agent.uid,
               run.id,
               second_attempt.attempt_id,
               %{"decision_needed" => true},
               now: DateTime.add(@now, 3, :second)
             )

    assert emitted.type == "automation_job.emitted"
    assert get_in(emitted.data, ["automation_job_run_id"]) == run.id
    assert get_in(emitted.data, ["payload"]) == %{"decision_needed" => true}

    assert {:ok, failed} =
             AutomationJobs.infrastructure_failure(
               run.id,
               second_attempt.attempt_id,
               :worker_replay_exhausted,
               :exhausted,
               now: DateTime.add(@now, 4, :second)
             )

    assert failed.status == :failed
    assert failed.attempts == 2
    assert failed.error =~ "worker_replay_exhausted"

    assert %Signal{type: "automation_job.run_failed"} =
             Repo.get_by!(Signal,
               agent_uid: agent.uid,
               session_id: source.session_id,
               type: "automation_job.run_failed"
             )
  end

  test "a run waits for its Agent's Worker without an attempt, and a cancelled run stops waiting" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    run = enqueue!(job, trigger_event("waits-for-worker"))

    assert {:snooze, 10} = execute(run, attempt: 1)
    assert %Run{status: :queued, attempts: 0} = Repo.get!(Run, run.id)
    assert %AgentWorker{wanted_until: %DateTime{}} = Repo.get!(AgentWorker, agent.uid)
    assert_enqueued(worker: ReconcileJob, args: %{"agent_uid" => agent.uid})

    Repo.update_all(where(AgentWorker, agent_uid: ^agent.uid), set: [wanted_until: nil])

    assert {:ok, %{status: :cancelled}} =
             AutomationJobs.cancel_job(agent.uid, source.session_id, job.id)

    assert :ok = execute(run, attempt: 1)
    assert %AgentWorker{wanted_until: nil} = Repo.get!(AgentWorker, agent.uid)
  end

  test "a Worker that stays not ready for ready_timeout costs one attempt, and the last one fails the run" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source, wake_on_failure: true)
    run = enqueue!(job, trigger_event("worker-never-ready"))

    wait_past_ready_timeout(run)
    assert {:error, :agent_worker_unavailable} = execute(run, attempt: 1)

    assert %Run{status: :queued, attempts: 1, attempt_id: nil, error: error} =
             Repo.get!(Run, run.id)

    assert error =~ "agent_worker_unavailable"

    waiting_since = Repo.get!(Run, run.id).worker_wait_started_at
    assert {:error, :agent_worker_unavailable} = execute(run, attempt: 2)
    assert Repo.get!(Run, run.id).worker_wait_started_at == waiting_since

    assert :ok = execute(run, attempt: 5)
    assert %Run{status: :failed, attempts: 3} = Repo.get!(Run, run.id)

    assert %Signal{type: "automation_job.run_failed"} =
             Repo.get_by!(Signal,
               agent_uid: agent.uid,
               session_id: source.session_id,
               type: "automation_job.run_failed"
             )
  end

  test "a ready Worker clears its wait budget while Agent capacity is full" do
    assert {:ok, 1} =
             Ankole.AppConfigure.put_tenant_by_key("automation_jobs.max_running_per_agent", 1)

    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    waiting = enqueue!(job, trigger_event("capacity-waiting"))

    assert {:ok, %{status: :waiting_for_worker, worker: nil}} =
             AutomationJobs.start_attempt(waiting.id, now: @now)

    assert Repo.reload!(waiting).worker_wait_started_at == @now

    wait_past_ready_timeout(waiting)
    expired_wait = Repo.reload!(waiting).worker_wait_started_at

    route = "automation-capacity-#{agent.uid}"
    :ok = Ankole.AgentWorkers.WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> Ankole.AgentWorkers.WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    blocker = enqueue!(job, trigger_event("capacity-running"))
    assert {:ok, %{run: running}} = AutomationJobs.start_attempt(blocker.id)

    assert {:snooze, 10} = execute(waiting, attempt: 1)

    assert %Run{
             status: :queued,
             attempts: 0,
             attempt_id: nil,
             started_at: nil,
             worker_wait_started_at: nil
           } = Repo.reload!(waiting)

    refute_receive {:actor_lane, %{body: {:rpc_request, _}}}

    assert {:ok, :marked_stale} =
             Ankole.AgentWorkers.WorkerAdmission.mark_route_unusable(route, :socket_closed)

    assert {:error, :agent_worker_unavailable} = Ankole.AgentWorkers.ready_worker(agent.uid)
    assert {:snooze, 10} = execute(waiting, attempt: 1)
    assert Repo.reload!(waiting).worker_wait_started_at == nil

    assert {:ok, %Run{status: :succeeded}} =
             AutomationJobs.finish_attempt(running.id, running.attempt_id, %{status: "succeeded"})

    before_probe = DateTime.utc_now(:microsecond)
    assert {:snooze, 10} = execute(waiting, attempt: 1)

    assert %Run{
             status: :queued,
             attempts: 0,
             attempt_id: nil,
             started_at: nil,
             worker_wait_started_at: %DateTime{} = fresh_wait
           } = Repo.reload!(waiting)

    assert DateTime.compare(fresh_wait, before_probe) in [:gt, :eq]

    assert DateTime.diff(fresh_wait, expired_wait, :millisecond) >
             Settings.current().ready_timeout_ms

    assert {:snooze, 10} = execute(waiting, attempt: 1)
    assert %Run{attempts: 0, worker_wait_started_at: ^fresh_wait} = Repo.reload!(waiting)
  end

  test "full capacity preserves an expired Worker wait until admission can resume" do
    assert {:ok, 1} =
             Ankole.AppConfigure.put_tenant_by_key("automation_jobs.max_running_per_agent", 1)

    %{principal: agent} = agent_fixture()
    job = agent.uid |> source_event!() |> job!()
    waiting = enqueue!(job, trigger_event("expired-capacity-wait"))

    assert {:ok, %{status: :waiting_for_worker, worker: nil}} =
             AutomationJobs.start_attempt(waiting.id, now: @now)

    route = "automation-expired-#{agent.uid}"
    assert {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    blocker = enqueue!(job, trigger_event("expired-capacity-blocker"))
    assert {:ok, %{run: running}} = AutomationJobs.start_attempt(blocker.id)

    assert {:ok, :marked_stale} =
             Ankole.AgentWorkers.WorkerAdmission.mark_route_unusable(route, :socket_closed)

    for _probe <- 1..2 do
      assert {:snooze, 10} = execute(waiting, attempt: 1)

      assert %Run{status: :queued, attempts: 0, worker_wait_started_at: @now} =
               Repo.reload!(waiting)
    end

    assert {:ok, %Run{status: :succeeded}} =
             AutomationJobs.finish_attempt(running.id, running.attempt_id, %{status: "succeeded"})

    assert {:error, :agent_worker_unavailable} = execute(waiting, attempt: 1)

    assert %Run{status: :queued, attempts: 1, worker_wait_started_at: @now} =
             Repo.reload!(waiting)
  end

  test "an infrastructure retry starts a new execution budget for adoption" do
    %{principal: agent} = agent_fixture()

    run =
      agent.uid |> source_event!() |> job!() |> enqueue!(trigger_event("fresh-attempt-budget"))

    first_started_at = DateTime.add(DateTime.utc_now(:microsecond), -611, :second)

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: first}} =
             AutomationJobs.start_attempt(run.id, now: first_started_at)

    assert {:ok, %Run{status: :queued, started_at: ^first_started_at}} =
             AutomationJobs.infrastructure_failure(
               run.id,
               first.attempt_id,
               :socket_closed,
               :retry
             )

    retry_started_at = DateTime.utc_now(:microsecond)

    assert {:ok, %{run: retry}} =
             AutomationJobs.start_attempt(run.id, now: retry_started_at)

    assert retry.started_at == retry_started_at
    assert Repo.reload!(retry).started_at == retry_started_at
    assert retry.attempts == 2
    refute retry.attempt_id == first.attempt_id
    assert DateTime.diff(retry.started_at, first.started_at, :millisecond) >= 611_000

    assert {:snooze, 10} = execute(retry, attempt: 3)

    assert %Run{status: :running, attempts: 2, attempt_id: attempt_id, error: nil} =
             Repo.reload!(run)

    assert attempt_id == retry.attempt_id
  end

  test "a lost Worker connection after dispatch records unknown outcome without automatic replay" do
    %{principal: agent} = agent_fixture()
    route = "automation-loss-#{agent.uid}"
    :ok = Ankole.AgentWorkers.WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> Ankole.AgentWorkers.WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    run =
      agent.uid
      |> source_event!()
      |> job!()
      |> enqueue!(trigger_event("disconnected-after-dispatch"))

    pending = Task.async(Repo.bind_tenant(fn -> execute(run, attempt: 1) end))
    assert_receive {:actor_lane, %{body: {:rpc_request, %{method: "automation_job.run"}}}}, 2_000
    :ok = Ankole.AgentWorkers.WorkerRoute.unregister_local_worker(route)
    assert :ok = Task.await(pending)
    assert %Run{status: :failed, attempts: 1, error: error} = Repo.get!(Run, run.id)
    assert error =~ "execution outcome unknown"
    assert :ok = execute(run, attempt: 2)
    refute_receive {:actor_lane, %{body: {:rpc_request, _}}}
  end

  test "only a confirmed preparation failure makes another automatic attempt eligible" do
    %{principal: agent} = agent_fixture()
    route = "automation-prepare-#{agent.uid}"
    :ok = Ankole.AgentWorkers.WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> Ankole.AgentWorkers.WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    run = agent.uid |> source_event!() |> job!() |> enqueue!(trigger_event("prepare-retry"))
    pending = Task.async(Repo.bind_tenant(fn -> execute(run, attempt: 1) end))
    assert_receive {:actor_lane, %{body: {:rpc_request, request}}}, 2_000

    :ok =
      Ankole.AgentWorkers.WorkerRoute.local_inbound(route, %Ankole.RuntimeFabric.V1.Envelope{
        body:
          {:rpc_error,
           %Ankole.RuntimeFabric.V1.RPCError{
             request_id: request.request_id,
             code: "automation_preparation_failed",
             message: "Drive unavailable",
             retryable: true,
             details_json: Torque.encode!(%{"execution_started" => false})
           }}
      })

    assert {:error, %{"code" => "automation_preparation_failed"}} = Task.await(pending)
    assert %Run{status: :queued, attempts: 1, attempt_id: nil} = Repo.get!(Run, run.id)
    retried = Task.async(Repo.bind_tenant(fn -> execute(run, attempt: 2) end))
    assert_receive {:actor_lane, %{body: {:rpc_request, next}}}, 2_000

    {bytes, _} =
      Ankole.RuntimeFabric.V1.AutomationJobRunResponse.encode!(
        %Ankole.RuntimeFabric.V1.AutomationJobRunResponse{status: "succeeded", exit_code: 0}
      )

    :ok =
      Ankole.AgentWorkers.WorkerRoute.local_inbound(route, %Ankole.RuntimeFabric.V1.Envelope{
        body:
          {:rpc_response,
           %Ankole.RuntimeFabric.V1.RPCResponse{
             request_id: next.request_id,
             payload: IO.iodata_to_binary(bytes)
           }}
      })

    assert :ok = Task.await(retried)
    assert %Run{status: :succeeded, attempts: 2} = Repo.get!(Run, run.id)
  end

  test "a replayed wake preserves an in-flight attempt and eventually reports unknown outcome" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    run = enqueue!(job, trigger_event("wake-after-node-loss"))

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: attempt}} = AutomationJobs.start_attempt(run.id)
    assert {:error, :automation_job_attempt_in_progress} = AutomationJobs.start_attempt(run.id)
    assert {:snooze, 10} = execute(run, attempt: 2)
    assert %Run{status: :running, attempts: 1, attempt_id: id} = Repo.get!(Run, run.id)
    assert id == attempt.attempt_id

    Repo.update_all(where(Run, id: ^run.id),
      set: [started_at: DateTime.add(DateTime.utc_now(), -611, :second)]
    )

    assert :ok = execute(run, attempt: 3)
    assert %Run{status: :failed, attempts: 1, error: error} = Repo.get!(Run, run.id)
    assert error =~ "execution outcome unknown"
    assert error =~ "verify external effects"
    assert :ok = execute(run, attempt: 4)
  end

  test "creation requires main.ts in the drive folder" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    drive_file_fixture(agent.uid, "automation/draft/notes.md", "no entry point yet")

    assert {:error, :automation_job_script_missing} =
             AutomationJobs.create_job(job_attrs(source, drive_prefix: "automation/draft"))
  end

  test "script failure is terminal and stores bounded log tails without scheduling another attempt" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    run = enqueue!(job, trigger_event("script-failure"))

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: attempt}} = AutomationJobs.start_attempt(run.id, now: @now)
    oversized = String.duplicate("a", 70_000)

    oversized_term =
      Enum.map(1..50, fn index -> {index, String.duplicate("unexpected", 1_000)} end)

    assert {:ok, failed} =
             AutomationJobs.finish_attempt(
               run.id,
               attempt.attempt_id,
               %{
                 status: "failed",
                 exit_code: 17,
                 error: oversized_term,
                 stdout: oversized,
                 stderr: "schema mismatch\nfull stack",
                 stdout_truncated: true,
                 stderr_truncated: false
               },
               now: DateTime.add(@now, 1, :second)
             )

    assert failed.status == :failed
    assert failed.exit_code == 17
    assert is_binary(failed.error)
    assert byte_size(failed.error) <= 65_536
    assert byte_size(failed.stdout) <= 65_536
    assert failed.stderr == "schema mismatch\nfull stack"
    assert failed.attempts == 1
    assert failed.attempt_id == nil
    assert Repo.aggregate(Signal, :count) == 1
  end

  test "cancelling a job cancels queued runs but lets a running attempt finish and emit" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    running = enqueue!(job, trigger_event("running"))
    queued = enqueue!(job, trigger_event("queued"))

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: attempt}} = AutomationJobs.start_attempt(running.id, now: @now)

    assert {:ok, %{status: :cancelled, automation_job: cancelled}} =
             AutomationJobs.cancel_job(
               agent.uid,
               source.session_id,
               job.id,
               now: DateTime.add(@now, 1, :second)
             )

    assert cancelled.status == :cancelled
    assert Repo.get!(Run, queued.id).status == :cancelled
    assert Repo.get!(Run, running.id).status == :running

    assert {:ok, %Signal{type: "automation_job.emitted"}} =
             AutomationJobs.emit_event(
               agent.uid,
               running.id,
               attempt.attempt_id,
               %{"finished_after_cancel" => true},
               now: DateTime.add(@now, 2, :second)
             )

    assert {:ok, succeeded} =
             AutomationJobs.finish_attempt(
               running.id,
               attempt.attempt_id,
               %{status: "succeeded", exit_code: 0},
               now: DateTime.add(@now, 3, :second)
             )

    assert succeeded.status == :succeeded

    assert {:error, {:automation_job_not_active, :cancelled}} =
             AutomationJobs.validate_bindable_in_tx(Repo, job.id, agent.uid)
  end

  test "a nil owner session lists and reads jobs across every session of one agent" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    first = source_event!(agent.uid)
    second = source_event!(agent.uid)
    one = job!(first)
    two = job!(second)

    listed = AutomationJobs.list_jobs(agent.uid, nil)

    assert MapSet.new(listed, & &1.id) == MapSet.new([one.id, two.id])

    assert MapSet.new(listed, & &1.owner_session_id) ==
             MapSet.new([first.session_id, second.session_id])

    assert {:ok, %{automation_job: found}} = AutomationJobs.show_job(agent.uid, nil, one.id)
    assert found.id == one.id

    assert AutomationJobs.show_job(other_agent.uid, nil, one.id) ==
             {:error, :automation_job_not_found}
  end

  test "deleting an Agent removes its automation jobs and run ledger" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    run = enqueue!(job, trigger_event("agent-deletion"))
    due_at = DateTime.add(@now, 5, :minute)

    assert {:ok, %{scheduled_event: scheduled}} =
             Schedule.create_check_back_later(
               checkback_attrs(source, due_at, "agent-deletion-checkback", job.id),
               now: @now
             )

    assert {:ok, _agent} = Repo.delete(agent)
    refute Repo.get(Ankole.AutomationJobs.Schemas.Job, job.id)
    refute Repo.get(Run, run.id)
    refute Repo.get(ScheduledEvent, scheduled.id)
  end

  test "a bound checkback atomically creates a run with the direct Signal envelope" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    due_at = DateTime.add(@now, 5, :minute)

    attrs = %{
      "source_signal_id" => source.id,
      "agent_uid" => agent.uid,
      "session_id" => source.session_id,
      "binding_name" => source.reply_binding_name,
      "tool_call_id" => "automation-checkback-call",
      "idempotency_key" => "automation-checkback-key",
      "schedule" => %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"},
      "reason" => "Check a deterministic condition.",
      "check" => "Read the source and compare the value.",
      "context_summary" => "Wake only when judgment is needed.",
      "reply_route" => %{
        "conversation_id" => source.conversation_id,
        "provider_thread_id" => source.provider_thread_id,
        "provider_message_id" => source.provider_message_id
      },
      "source_provenance" => %{"kind" => "test"},
      "automation_job_id" => job.id
    }

    assert {:ok, %{scheduled_event: scheduled}} =
             Schedule.create_check_back_later(attrs, now: @now)

    assert scheduled.automation_job_id == job.id

    assert {:ok, %{status: :fired, automation_job_run: run}} =
             Schedule.fire_due_event(scheduled.id, now: due_at)

    assert run.automation_job_id == job.id
    assert run.status == :queued
    assert run.event["specversion"] == "1.0"
    assert run.event["type"] == "check_back_later.wakeup"
    assert run.event["id"] == "check_back_later:#{scheduled.id}:wakeup"

    assert get_in(run.event, ["data", "wake_payload", "check"]) ==
             "Read the source and compare the value."

    fired = Repo.get!(ScheduledEvent, scheduled.id)
    assert fired.status == :fired
    assert fired.automation_job_run_id == run.id
    assert fired.signal_id == nil

    assert Repo.aggregate(
             from(event in Signal, where: event.type == "check_back_later.wakeup"),
             :count
           ) ==
             0
  end

  test "checkback updates can bind and clear an automation job" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    due_at = DateTime.add(@now, 5, :minute)

    assert {:ok, %{scheduled_event: initial}} =
             Schedule.create_check_back_later(
               checkback_attrs(source, due_at, "checkback-initial", nil),
               now: @now
             )

    assert initial.automation_job_id == nil

    assert {:ok, %{scheduled_event: bound}} =
             Schedule.update_checkback(
               initial.id,
               source
               |> checkback_attrs(due_at, "checkback-bind-key", job.id)
               |> Map.delete("schedule"),
               now: DateTime.add(@now, 1, :second)
             )

    assert bound.id == initial.id
    assert bound.automation_job_id == job.id

    assert {:ok, %{scheduled_event: direct}} =
             Schedule.update_checkback(
               initial.id,
               source
               |> checkback_attrs(due_at, "checkback-clear-key", nil)
               |> Map.delete("schedule"),
               now: DateTime.add(@now, 2, :second)
             )

    assert direct.automation_job_id == nil

    assert {:ok, %{status: :fired, signal: signal}} =
             Schedule.fire_due_event(direct.id, now: due_at)

    assert signal.type == "check_back_later.wakeup"
  end

  test "cron fires and manual runs use the current automation job binding" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    first_slot = DateTime.add(@now, 1, :minute)

    assert {:ok, %{cron_schedule: schedule}} =
             create_cron_schedule(
               %{
                 "agent_uid" => agent.uid,
                 "owner_session_id" => source.session_id,
                 "binding_name" => source.reply_binding_name,
                 "name" => "automation-cron-#{System.unique_integer([:positive])}",
                 "schedule" => %{
                   "kind" => "every",
                   "every_ms" => 60_000,
                   "anchor_at" => DateTime.to_iso8601(first_slot)
                 },
                 "payload" => %{"task" => "check deterministic state"},
                 "delivery" => %{
                   "targets" => [
                     %{
                       "binding_name" => source.reply_binding_name,
                       "conversation_id" => source.conversation_id,
                       "provider_thread_id" => source.provider_thread_id
                     }
                   ]
                 },
                 "idempotency_key" => "automation-cron-#{System.unique_integer([:positive])}",
                 "automation_job_id" => job.id
               },
               now: @now
             )

    assert schedule.automation_job_id == job.id
    assert Schedule.list_cron_runs(schedule.id, 10) == []

    assert {:ok, %{scheduled_event: manual}} =
             Schedule.run_cron_schedule(schedule.id,
               now: @now,
               tool_call_id: "automation-cron-manual"
             )

    assert manual.automation_job_id == job.id

    assert {:ok, %{automation_job_run: manual_run}} =
             Schedule.fire_due_event(manual.id, now: @now)

    assert manual_run.event["type"] == "cron.fire"
    assert get_in(manual_run.event, ["data", "wake_payload", "trigger"]) == "manual"

    assert {:ok, updated} =
             Schedule.update_cron_schedule(
               schedule.id,
               %{"automation_job_id" => nil},
               now: DateTime.add(@now, 1, :second)
             )

    assert updated.automation_job_id == nil

    # The retained manual fire keeps every stored value after the binding edit.
    fields =
      Ankole.Schedule.Schemas.ScheduledEvent
      |> Ash.Resource.Info.attribute_names()
      |> MapSet.to_list()

    assert Enum.map(Schedule.list_cron_runs(schedule.id, 10), &Map.take(&1, fields)) ==
             [Map.take(Repo.reload!(manual), fields)]

    assert {:ok, %{signal: signal, scheduled_event: automatic}} =
             Schedule.fire_cron(schedule.id, now: first_slot)

    assert automatic.automation_job_id == nil

    assert signal.type == "cron.fire"
  end

  test "a cron slot history rejects a second automation run" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    slot = DateTime.add(@now, 1, :minute)

    assert {:ok, %{cron_schedule: rule}} =
             create_cron_schedule(
               %{
                 "agent_uid" => agent.uid,
                 "owner_session_id" => source.session_id,
                 "binding_name" => source.reply_binding_name,
                 "name" => "automation-once",
                 "schedule" => %{
                   "kind" => "every",
                   "every_ms" => 60_000,
                   "anchor_at" => DateTime.to_iso8601(slot)
                 },
                 "payload" => %{},
                 "delivery" => %{
                   "targets" => [
                     %{
                       "binding_name" => source.reply_binding_name,
                       "conversation_id" => source.conversation_id
                     }
                   ]
                 },
                 "idempotency_key" => "automation-once",
                 "automation_job_id" => job.id
               },
               now: @now
             )

    assert {:ok, %{automation_job_run: run}} = Schedule.fire_cron(rule.id, now: slot)
    Repo.update!(Ecto.Changeset.change(Repo.reload!(rule), next_fire_at: slot))
    assert {:error, %Ash.Error.Invalid{errors: errors}} = Schedule.fire_cron(rule.id, now: slot)

    assert Enum.any?(errors, fn error ->
             error.field == :cron_schedule_id and
               error.private_vars[:constraint] == "scheduled_events_cron_slot_index" and
               error.private_vars[:constraint_type] == :unique
           end)

    Ankole.DataCase.assert_persisted_equal(
      Repo.all(from(r in Run, where: r.automation_job_id == ^job.id)),
      [run]
    )
  end

  test "Ash actions own initial state, attempt increments and terminal immutability" do
    %{principal: agent} = agent_fixture()
    job = agent.uid |> source_event!() |> job!()
    attrs = %{automation_job_id: job.id, event: trigger_event("state-owner")}

    for forbidden <- [%{status: :running}, %{attempts: 99}] do
      assert {:error, %Ash.Error.Invalid{}} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(Run, :enqueue, Map.merge(attrs, forbidden))
               end)
    end

    refute Repo.exists?(from(run in Run, where: run.automation_job_id == ^job.id))

    run = enqueue!(job, attrs.event)

    assert {:error, %Ash.Error.Invalid{}} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(run, :settle, %{status: :succeeded, finished_at: @now})
             end)

    assert Repo.reload!(run).status == :queued

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: running}} = AutomationJobs.start_attempt(run.id, now: @now)
    assert running.attempts == 1

    assert {:error, %Ash.Error.Invalid{}} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(running, :start, %{
                 attempt_id: Ecto.UUID.generate(),
                 started_at: @now
               })
             end)

    assert Repo.reload!(running).attempts == 1

    assert {:ok, finished} =
             AutomationJobs.finish_attempt(
               running.id,
               running.attempt_id,
               %{status: "succeeded", exit_code: 0},
               now: @now
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(finished, :retry, %{attempt_id: nil, error: "cannot resurrect"})
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.reload!(finished), finished)
  end

  defp execute(run, opts) do
    perform_job(ExecuteRun, %{"automation_job_run_id" => run.id}, opts)
  end

  defp wait_past_ready_timeout(run) do
    waiting_since =
      DateTime.add(DateTime.utc_now(), -Settings.current().ready_timeout_ms - 1_000, :millisecond)

    Repo.update_all(where(Run, id: ^run.id), set: [worker_wait_started_at: waiting_since])
  end

  defp job!(source, opts \\ []) do
    drive_file_fixture(source.agent_uid, "automation/test/main.ts")
    assert {:ok, job} = AutomationJobs.create_job(job_attrs(source, opts))
    job
  end

  defp job_attrs(source, opts) do
    %{
      agent_uid: source.agent_uid,
      owner_session_id: source.session_id,
      source_signal_id: source.id,
      provider_message_id: source.provider_message_id,
      source_provenance: %{"kind" => "test"},
      reply_route: %{
        "binding_name" => source.reply_binding_name,
        "conversation_id" => source.conversation_id,
        "provider_thread_id" => source.provider_thread_id,
        "provider_message_id" => source.provider_message_id
      },
      drive_prefix: Keyword.get(opts, :drive_prefix, "automation/test"),
      label: "Deterministic test consumer",
      wake_on_failure: Keyword.get(opts, :wake_on_failure, false)
    }
  end

  defp enqueue!(job, event) do
    assert {:ok, %{status: :queued, automation_job_run: run}} =
             Repo.transact(fn repo ->
               AutomationJobs.enqueue_run_in_tx(repo, job.id, job.agent_uid, event, now: @now)
             end)

    run
  end

  defp trigger_event(id) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "test://automation-jobs",
      "type" => "test.triggered",
      "data" => %{"id" => id}
    }
  end

  defp checkback_attrs(source, due_at, key, automation_job_id) do
    %{
      "source_signal_id" => source.id,
      "agent_uid" => source.agent_uid,
      "session_id" => source.session_id,
      "binding_name" => source.reply_binding_name,
      "tool_call_id" => "#{key}-call",
      "idempotency_key" => key,
      "schedule" => %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"},
      "reason" => "Check a deterministic condition.",
      "check" => "Read the source and compare the value.",
      "context_summary" => "Wake only when judgment is needed.",
      "reply_route" => %{
        "conversation_id" => source.conversation_id,
        "provider_thread_id" => source.provider_thread_id,
        "provider_message_id" => source.provider_message_id
      },
      "source_provenance" => %{"kind" => "test"},
      "automation_job_id" => automation_job_id
    }
  end

  defp source_event!(agent_uid) do
    Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid,
      binding_name: "lark",
      source: "test://automation-source",
      now: @now
    )
  end

  defp create_cron_schedule(attrs, opts) do
    Schedule.create_cron_schedule(
      attrs,
      Keyword.put_new(opts, :created_by, %{
        "kind" => "operator_api",
        "principal_uid" =>
          to_string(%Ankole.ActorRef{
            tenant_id: Repo.tenant_id!(),
            uid: attrs["agent_uid"] || attrs[:agent_uid]
          })
      })
    )
  end
end
