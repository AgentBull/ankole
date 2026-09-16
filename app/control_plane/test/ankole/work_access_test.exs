defmodule Ankole.WorkAccessTest do
  use Ankole.SignalsGateway.ActorRuntimeCase
  alias Ankole.{AuthZ, AutomationJobs, Schedule, Workflow}
  alias Ankole.Principals.{HumanAccess, WorkAccess, WorkCleanup}
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle

  test "a committed admission may finish after disablement; retry and new work cannot start" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _} = admit_worker(route)
    source = source_event(agent.uid, human.uid)
    key = %{agent_uid: agent.uid, session_id: source.session_id}
    assert {:ok, admitted} = TurnLifecycle.start_worker_turn(key, source)
    assert {:ok, disabled} = HumanAccess.disable(human.uid, "Offboarding", nil, "disable")
    assert {:ok, %{running: 1}} = WorkCleanup.cleanup(human.uid, disabled.access_version)
    assert Repo.get!(ActorEvent, source.id).input_state == "open"
    assert {:error, :human_access_revoked} = TurnLifecycle.start_worker_turn(key, source)
    assert {:error, :human_access_revoked} = Schedule.create_check_back_later(checkback(source))

    assert {:ok, _} = complete_turn_silent(admitted.turn_ref)
    assert Repo.get!(ActorEvent, source.id).completed_at
    assert {:ok, %{running: 0}} = WorkCleanup.cleanup(human.uid, disabled.access_version)

    [restriction] = HumanAccess.restrictions(human.uid)

    assert {:ok, _} =
             HumanAccess.clear_restriction(human.uid, restriction.id, nil, "Verified", "clear")

    assert {:ok, review} = AuthZ.restoration_review(human.uid)

    assert {:ok, _} =
             HumanAccess.restore(
               human.uid,
               review.fingerprint,
               nil,
               "Approved permissions",
               "restore"
             )

    assert {:error, :human_access_revoked} =
             Repo.transact(fn repo -> WorkAccess.check_in_tx(repo, source) end)

    fresh = source_event(agent.uid, human.uid)
    assert {:ok, %{scheduled_event: event}} = Schedule.create_check_back_later(checkback(fresh))
    assert event.human_access_version == disabled.access_version
  end

  test "cleanup stops future domain work, preserves independent service work, and survives restoration" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    source = source_event(agent.uid, human.uid)
    service_source = source_event(agent.uid, agent.uid)

    assert {:ok, %{scheduled_event: pending}} =
             Schedule.create_check_back_later(checkback(source))

    assert {:ok, %{scheduled_event: independent}} =
             Schedule.create_check_back_later(checkback(service_source))

    assert {:ok, %{cron_schedule: cron}} =
             Schedule.create_cron_schedule(cron(source),
               created_by: %{"kind" => "turn", "actor_event_id" => source.id}
             )

    assert {:ok, job} = AutomationJobs.create_job(automation(source))

    assert {:ok, %{automation_job_run: queued}} =
             Repo.transact(fn repo ->
               AutomationJobs.enqueue_run_in_tx(repo, job.id, agent.uid, trigger("queued"))
             end)

    assert {:ok, %{automation_job_run: running}} =
             Repo.transact(fn repo ->
               AutomationJobs.enqueue_run_in_tx(repo, job.id, agent.uid, trigger("running"))
             end)

    assert {:ok, %{run: running}} = AutomationJobs.start_attempt(running.id)
    assert {:ok, %{run: workflow}} = Workflow.create_with_dispatch(workflow(source))

    assert {:ok, %{new_calls: [call]}} =
             Workflow.commit_replay_pending(
               workflow.id,
               [%{namespace: nil, name: "agent", arguments: %{"prompt" => "Check status"}}],
               0
             )

    assert {:ok, _} =
             Repo.transact(fn repo -> Workflow.claim_task_in_tx(repo, call.id, agent.uid, 4) end)

    assert {:ok, disabled} = HumanAccess.disable(human.uid, "Offboarding", nil, "disable")

    assert_enqueued(
      worker: WorkCleanup,
      args: %{"human_uid" => human.uid, "version" => disabled.access_version}
    )

    assert {:ok, _} = WorkCleanup.cleanup(human.uid, disabled.access_version)

    assert Repo.get!(Ankole.Schedule.Schemas.ScheduledEvent, pending.id).status == "cancelled"
    assert Repo.get!(Ankole.Schedule.Schemas.ScheduledEvent, independent.id).status == "scheduled"
    assert Repo.get!(Ankole.Schedule.Schemas.CronSchedule, cron.id).status == "paused"
    assert {:error, :human_access_revoked} = Schedule.resume_cron_schedule(cron.id)
    assert {:error, :human_access_revoked} = Schedule.run_cron_schedule(cron.id)
    assert Repo.get!(Ankole.AutomationJobs.Schemas.Run, queued.id).status == "cancelled"
    assert Repo.get!(Ankole.AutomationJobs.Schemas.Run, running.id).status == "running"

    assert {:ok, _} =
             AutomationJobs.finish_attempt(running.id, running.attempt_id, %{
               "status" => "succeeded",
               "exit_code" => 0
             })

    assert {:error, :human_access_revoked} = Workflow.commit_replay_pending(workflow.id, [], 1)

    assert {:ok, %{accepted: true, call: %{status: "succeeded"}}} =
             Workflow.submit_result(call.id, agent.uid, Workflow.task_session_id(call.id), %{
               "ok" => true,
               "value" => "Completed admitted work"
             })

    assert Repo.get!(Ankole.Workflow.Schemas.Run, workflow.id).status == "cancelled"
    assert {:ok, _} = WorkCleanup.cleanup(human.uid, disabled.access_version)
  end

  test "Background Job admission and child creation use the captured Human version" do
    %{principal: agent} = Ankole.AIGatewayCase.background_agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    source = source_event(agent.uid, human.uid)

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => source.session_id,
      "source_actor_event_id" => source.id,
      "source_tool_call_id" => "background-test",
      "title" => "Review status",
      "task" => "Read status",
      "reply_route" => %{"binding_name" => "bot"}
    }

    assert {:ok, %{job: job}} = Ankole.BackgroundAgentJobs.create_with_dispatch(attrs)
    assert job.human_uid == human.uid

    assert {:ok, disabled} =
             HumanAccess.disable(human.uid, "Offboarding", nil, "background-disable")

    assert {:error, :human_access_revoked} =
             Ankole.BackgroundAgentJobs.create_with_dispatch(
               Map.put(attrs, "source_tool_call_id", "new-child")
             )

    assert {:ok, _} = WorkCleanup.cleanup(human.uid, disabled.access_version)
    assert Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, job.id).status == "stopped"
  end

  test "missing source evidence is not independent service authority" do
    %{principal: agent} = agent_fixture()
    source = source_event(agent.uid, nil)
    assert source.authorization_kind == "review_required"

    assert {:error, :work_authorization_review_required} =
             Schedule.create_check_back_later(checkback(source))

    assert {:error, :work_authorization_review_required} =
             Repo.transact(fn repo -> WorkAccess.check_in_tx(repo, source) end)
  end

  test "an operator can classify unknown legacy work once and the review is audited" do
    %{principal: agent} = agent_fixture()
    %{principal: reviewer} = Ankole.PrincipalsFixtures.human_fixture()
    source = source_event(agent.uid, nil)
    assert Enum.any?(WorkAccess.list_unresolved(), &(&1.id == source.id))

    assert {:ok, %{authorization_kind: "service"}} =
             WorkAccess.classify(
               "actor_event",
               source.id,
               nil,
               reviewer.uid,
               "Verified an independent service trigger"
             )

    assert [%{action: "classify_work"}] = HumanAccess.history(reviewer.uid)

    assert {:error, :work_review_changed} =
             WorkAccess.classify(
               "actor_event",
               source.id,
               reviewer.uid,
               reviewer.uid,
               "Cannot replace an established authority"
             )

    refute Enum.any?(WorkAccess.list_unresolved(), &(&1.id == source.id))
  end

  defp source_event(agent_uid, sender_uid) do
    id = Ecto.UUID.generate()

    {:ok, event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        sender_key: sender_uid,
        binding_name: "bot",
        session_id: "work:#{id}",
        source_event_id: id,
        type: "im.message.addressed",
        available_at: DateTime.utc_now(),
        payload: %{"data" => %{"text" => "Check status"}}
      })

    event
  end

  defp checkback(source),
    do: %{
      "agent_uid" => source.agent_uid,
      "session_id" => source.session_id,
      "binding_name" => source.binding_name,
      "source_actor_event_id" => source.id,
      "tool_call_id" => "check-#{source.id}",
      "idempotency_key" => source.id,
      "schedule" => %{"after" => %{"value" => 5, "unit" => "minute"}, "timezone" => "Etc/UTC"},
      "reason" => "Check status",
      "check" => "Read the current status"
    }

  defp cron(source),
    do: %{
      "agent_uid" => source.agent_uid,
      "owner_session_id" => source.session_id,
      "binding_name" => source.binding_name,
      "name" => "check-status",
      "idempotency_key" => source.id,
      "payload" => %{"task" => "Check status"},
      "delivery" => %{
        "targets" => [
          %{"binding_name" => source.binding_name, "signal_channel_id" => "work-access-test"}
        ]
      },
      "schedule" => %{
        "kind" => "every",
        "every_ms" => 86_400_000,
        "anchor_at" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
      }
    }

  defp automation(source),
    do: %{
      agent_uid: source.agent_uid,
      owner_session_id: source.session_id,
      source_actor_event_id: source.id,
      source_provenance: %{"kind" => "turn"},
      reply_route: %{"binding_name" => source.binding_name},
      directory_path: "/agents/work-test/automation/check",
      label: "Check status"
    }

  defp trigger(id),
    do: %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "test://work-access",
      "type" => "test.triggered",
      "data" => %{}
    }

  defp workflow(source),
    do: %{
      "agent_uid" => source.agent_uid,
      "owner_session_id" => source.session_id,
      "source_actor_event_id" => source.id,
      "source_tool_call_id" => "workflow-#{source.id}",
      "reply_route" => %{"binding_name" => source.binding_name},
      "title" => "Check status",
      "script" => "return await agent('Check status');",
      "concurrency" => 4,
      "max_agent_calls" => 8
    }
end
