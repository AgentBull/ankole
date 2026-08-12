defmodule Ankole.AutomationJobsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent

  @now ~U[2026-07-30 09:00:00.000000Z]

  test "attempt fences reject stale completion and emission after infrastructure replay" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source, wake_on_failure: true)
    run = enqueue!(job, trigger_event("first"))

    assert_enqueued(worker: ExecuteRun, args: %{"automation_job_run_id" => run.id})
    assert run.status == "queued"
    assert run.attempts == 0

    assert {:ok, %{run: first_attempt}} =
             AutomationJobs.start_attempt(run.id, now: @now)

    assert first_attempt.status == "running"
    assert first_attempt.attempts == 1
    assert Ecto.UUID.cast(first_attempt.attempt_id) != :error

    assert {:ok, replayable} =
             AutomationJobs.infrastructure_failure(
               run.id,
               first_attempt.attempt_id,
               :socket_closed,
               :retry,
               now: DateTime.add(@now, 1, :second)
             )

    assert replayable.status == "queued"
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
    assert get_in(emitted.payload, ["data", "automation_job_run_id"]) == run.id
    assert get_in(emitted.payload, ["data", "payload"]) == %{"decision_needed" => true}

    assert {:ok, failed} =
             AutomationJobs.infrastructure_failure(
               run.id,
               second_attempt.attempt_id,
               :worker_replay_exhausted,
               :exhausted,
               now: DateTime.add(@now, 4, :second)
             )

    assert failed.status == "failed"
    assert failed.attempts == 2
    assert failed.error =~ "worker_replay_exhausted"

    assert %ActorEvent{type: "automation_job.run_failed"} =
             Repo.get_by!(ActorEvent,
               agent_uid: agent.uid,
               session_id: source.session_id,
               type: "automation_job.run_failed"
             )
  end

  test "script failure is terminal and stores bounded log tails without scheduling another attempt" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    run = enqueue!(job, trigger_event("script-failure"))

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

    assert failed.status == "failed"
    assert failed.exit_code == 17
    assert is_binary(failed.error)
    assert byte_size(failed.error) <= 65_536
    assert byte_size(failed.stdout) <= 65_536
    assert failed.stderr == "schema mismatch\nfull stack"
    assert failed.attempts == 1
    assert failed.attempt_id == nil
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "cancelling a job cancels queued runs but lets a running attempt finish and emit" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    running = enqueue!(job, trigger_event("running"))
    queued = enqueue!(job, trigger_event("queued"))

    assert {:ok, %{run: attempt}} = AutomationJobs.start_attempt(running.id, now: @now)

    assert {:ok, %{status: :cancelled, automation_job: cancelled}} =
             AutomationJobs.cancel_job(
               agent.uid,
               source.session_id,
               job.id,
               now: DateTime.add(@now, 1, :second)
             )

    assert cancelled.status == "cancelled"
    assert Repo.get!(Run, queued.id).status == "cancelled"
    assert Repo.get!(Run, running.id).status == "running"

    assert {:ok, %ActorEvent{type: "automation_job.emitted"}} =
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

    assert succeeded.status == "succeeded"

    assert {:error, {:automation_job_not_active, "cancelled"}} =
             AutomationJobs.validate_bindable_in_tx(Repo, job.id, agent.uid, @now)
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

  test "a bound checkback atomically creates a run with the direct ActorEvent envelope" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    due_at = DateTime.add(@now, 5, :minute)

    attrs = %{
      "agent_uid" => agent.uid,
      "session_id" => source.session_id,
      "binding_name" => source.binding_name,
      "tool_call_id" => "automation-checkback-call",
      "idempotency_key" => "automation-checkback-key",
      "schedule" => %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"},
      "reason" => "Check a deterministic condition.",
      "check" => "Read the source and compare the value.",
      "context_summary" => "Wake only when judgment is needed.",
      "reply_route" => %{
        "signal_channel_id" => source.signal_channel_id,
        "provider_thread_id" => source.provider_thread_id,
        "source_entry_id" => source.source_entry_id
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
    assert run.status == "queued"
    assert run.event["specversion"] == "1.0"
    assert run.event["type"] == "check_back_later.wakeup"
    assert run.event["id"] == "check_back_later:#{scheduled.id}:wakeup"

    assert get_in(run.event, ["data", "wake_payload", "check"]) ==
             "Read the source and compare the value."

    fired = Repo.get!(ScheduledEvent, scheduled.id)
    assert fired.status == "fired"
    assert fired.automation_job_run_id == run.id
    assert fired.actor_event_id == nil

    assert Repo.aggregate(
             from(event in ActorEvent, where: event.type == "check_back_later.wakeup"),
             :count
           ) ==
             0
  end

  test "checkback replacement can bind and clear an automation job" do
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

    assert {:ok, %{status: :fired, actor_event: actor_event}} =
             Schedule.fire_due_event(direct.id, now: due_at)

    assert actor_event.type == "check_back_later.wakeup"
  end

  test "cron fires and manual runs use the current automation job binding" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = job!(source)
    first_slot = DateTime.add(@now, 1, :minute)

    assert {:ok, %{cron_schedule: schedule}} =
             Schedule.create_cron_schedule(
               %{
                 "agent_uid" => agent.uid,
                 "owner_session_id" => source.session_id,
                 "binding_name" => source.binding_name,
                 "name" => "automation-cron-#{System.unique_integer([:positive])}",
                 "schedule" => %{
                   "kind" => "every",
                   "every_ms" => 60_000,
                   "anchor_at" => DateTime.to_iso8601(first_slot)
                 },
                 "payload" => %{"task" => "check deterministic state"},
                 "delivery" => %{
                   "signal_channel_id" => source.signal_channel_id,
                   "provider_thread_id" => source.provider_thread_id
                 },
                 "idempotency_key" => "automation-cron-#{System.unique_integer([:positive])}",
                 "automation_job_id" => job.id
               },
               now: @now
             )

    assert schedule.automation_job_id == job.id
    assert [automatic] = Schedule.list_cron_runs(schedule.id, 10)
    assert automatic.automation_job_id == job.id

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

    same_automatic =
      schedule.id
      |> Schedule.list_cron_runs(10)
      |> Enum.find(&(&1.id == automatic.id))

    assert same_automatic.id == automatic.id
    assert same_automatic.automation_job_id == nil

    assert {:ok, %{actor_event: actor_event}} =
             Schedule.fire_due_event(same_automatic.id, now: first_slot)

    assert actor_event.type == "cron.fire"
  end

  defp job!(source, opts \\ []) do
    assert {:ok, job} =
             AutomationJobs.create_job(%{
               agent_uid: source.agent_uid,
               owner_session_id: source.session_id,
               source_actor_event_id: source.id,
               source_entry_id: source.source_entry_id,
               source_provenance: %{"kind" => "test"},
               reply_route: %{
                 "binding_name" => source.binding_name,
                 "signal_channel_id" => source.signal_channel_id,
                 "provider_thread_id" => source.provider_thread_id,
                 "source_entry_id" => source.source_entry_id
               },
               directory_path: "/agents/#{source.agent_uid}/automation/test",
               label: "Deterministic test consumer",
               wake_on_failure: Keyword.get(opts, :wake_on_failure, false)
             })

    job
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
      "agent_uid" => source.agent_uid,
      "session_id" => source.session_id,
      "binding_name" => source.binding_name,
      "tool_call_id" => "#{key}-call",
      "idempotency_key" => key,
      "schedule" => %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"},
      "reason" => "Check a deterministic condition.",
      "check" => "Read the source and compare the value.",
      "context_summary" => "Wake only when judgment is needed.",
      "reply_route" => %{
        "signal_channel_id" => source.signal_channel_id,
        "provider_thread_id" => source.provider_thread_id,
        "source_entry_id" => source.source_entry_id
      },
      "source_provenance" => %{"kind" => "test"},
      "automation_job_id" => automation_job_id
    }
  end

  defp source_event!(agent_uid) do
    unique = System.unique_integer([:positive])

    assert {:ok, source} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent_uid,
               binding_name: "lark",
               session_id: "automation-session-#{unique}",
               source_event_id: "automation-source-#{unique}",
               signal_channel_id: "lark:chat:#{unique}",
               provider_thread_id: "thread-#{unique}",
               source_entry_id: "message-#{unique}",
               type: "im.message.addressed",
               available_at: @now,
               sender_key: nil,
               payload: trigger_event("source-#{unique}")
             })

    source
  end
end
