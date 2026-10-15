defmodule Ankole.WorkAccessTest do
  use Ankole.SessionsCase
  alias Ankole.{AuthZ, AutomationJobs, Schedule, Workflow}
  alias Ankole.Principals.HumanAccess
  alias Ankole.Principals.WorkAccess
  alias Ankole.Principals.WorkCleanup
  alias Ankole.Sessions.Admission

  test "suspension allows stopping and finishing existing work", %{tenant: tenant} do
    %{principal: agent} = agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    source = source_event(agent.uid, human.uid)

    assert {:ok, %{cron_schedule: cron}} =
             Schedule.create_cron_schedule(cron(source),
               created_by: %{"kind" => "turn", "signal_id" => source.id}
             )

    assert {:ok, %{run: run}} = Workflow.create_with_dispatch(workflow(source))
    Repo.update!(Ecto.Changeset.change(tenant, suspended_at: DateTime.utc_now()))
    assert {:ok, %{status: "paused"}} = Schedule.pause_cron_schedule(cron.id)
    assert {:error, :tenant_suspended} = Schedule.run_cron_schedule(cron.id)

    assert {:error, :tenant_suspended} =
             Workflow.commit_replay_pending(
               run.id,
               [%{namespace: nil, name: "agent", arguments: %{"prompt" => "new work"}}],
               0
             )

    assert Repo.reload!(run).status == "running"
    assert {:ok, %{new_calls: []}} = Workflow.commit_replay_pending(run.id, [], 0)
    assert {:ok, _} = Workflow.complete_replay(run.id, "finished existing work", 0)
  end

  test "a committed admission may finish after disablement; retry and new work cannot start" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    source = source_event(agent.uid, human.uid)
    key = %{agent_uid: agent.uid, session_id: source.session_id}
    assert {:ok, admitted} = Admission.admit(key, source)
    assert {:ok, disabled} = HumanAccess.disable(human.uid, "Offboarding", nil, "disable")
    assert {:ok, %{running: 1}} = WorkCleanup.cleanup(human.uid, disabled.access_version)
    assert Repo.get!(Signal, source.id).input_state == "open"

    assert {:error, :human_access_revoked} =
             Repo.transact(fn repo -> WorkAccess.check_in_tx(repo, source) end)

    assert {:error, :human_access_revoked} = Schedule.create_check_back_later(checkback(source))

    assert {:ok, _} = complete_turn_silent(admitted)
    assert Repo.get!(Signal, source.id).completed_at
    next = source_event(agent.uid, human.uid)
    assert {:ok, %{status: :access_revoked}} = Admission.admit(next, next)
    assert Repo.reload!(next).input_state == "dead_letter"
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
               created_by: %{"kind" => "turn", "signal_id" => source.id}
             )

    Ankole.FilesFixtures.drive_file_fixture(agent.uid, "automation/check/main.ts")
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
             Ankole.Repo.transact(fn repo ->
               Workflow.submit_result_in_tx(
                 repo,
                 call.id,
                 agent.uid,
                 Workflow.task_session_id(call.id),
                 %{
                   "ok" => true,
                   "value" => "Completed admitted work"
                 }
               )
             end)

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
      "source_signal_id" => source.id,
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
               "signal",
               source.id,
               nil,
               Ankole.ActorRef.from_principal(reviewer),
               "Verified an independent service trigger"
             )

    assert [%{action: "classify_work"}] = HumanAccess.history(reviewer.uid)

    assert {:error, :work_review_changed} =
             WorkAccess.classify(
               "signal",
               source.id,
               reviewer.uid,
               Ankole.ActorRef.from_principal(reviewer),
               "Cannot replace an established authority"
             )

    refute Enum.any?(WorkAccess.list_unresolved(), &(&1.id == source.id))
  end

  defp source_event(agent_uid, sender_uid) do
    original =
      Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid, binding_name: "bot")

    id = Ecto.UUID.generate()

    {:ok, signal} =
      Repo.transact(fn repo ->
        Ankole.Signals.accept_in_tx(repo, %{
          source: "test://work-access",
          id: id,
          type: "conversation.message.addressed",
          time: DateTime.utc_now(),
          sender: sender_uid,
          target: %{agent_uid: agent_uid, session_id: "work:#{id}"},
          data: %{"text" => "Check status"},
          reply_route: %{
            binding_name: original.reply_binding_name,
            conversation_id: original.conversation_id,
            provider_message_id: original.provider_message_id
          }
        })
      end)

    signal
  end

  defp checkback(source),
    do: %{
      "agent_uid" => source.agent_uid,
      "session_id" => source.session_id,
      "binding_name" => source.reply_binding_name,
      "source_signal_id" => source.id,
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
      "binding_name" => source.reply_binding_name,
      "name" => "check-status",
      "idempotency_key" => source.id,
      "payload" => %{"task" => "Check status"},
      "delivery" => %{
        "targets" => [
          %{
            "binding_name" => source.reply_binding_name,
            "conversation_id" => source.conversation_id
          }
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
      source_signal_id: source.id,
      source_provenance: %{"kind" => "turn"},
      reply_route: %{"binding_name" => source.reply_binding_name},
      drive_prefix: "automation/check",
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
      "source_signal_id" => source.id,
      "source_tool_call_id" => "workflow-#{source.id}",
      "reply_route" => %{"binding_name" => source.reply_binding_name},
      "title" => "Check status",
      "script" => "return await agent('Check status');",
      "concurrency" => 4,
      "max_agent_calls" => 8
    }
end
