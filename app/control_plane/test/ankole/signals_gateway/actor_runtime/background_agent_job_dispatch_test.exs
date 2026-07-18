defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobDispatchTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobWorkerConfig
  alias Ankole.AppConfigure
  alias Ankole.BackgroundAgentJobs

  test "dispatch starts a fenced non-conversation turn and increments attempts once" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "dispatch")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_start = turn_start_payload!(envelope)
    assert turn_start.turn.actor.session_id == actor_key.session_id
    refute Map.has_key?(turn_start, "model_ref")
    assert is_binary(Ankole.Kernel.RuntimeFabric.encode_envelope(envelope))
    assert decoded_request_context(turn_start)["turn_mode"] == "background_agent_job"
    assert decoded_request_context(turn_start)["job_id"] == job.id
    assert decoded_request_context(turn_start)["owner_session_id"] == job.owner_session_id
    assert decoded_request_context(turn_start)["attempts"] == 1

    refute Repo.get_by(Conversation,
             subject_uid: agent.uid,
             conversation_key: actor_key.session_id
           )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "running"
    assert persisted.attempts == 1
  end

  test "explicit steer resumes a settled job after prior execution attempts" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "settled-resume")
    assert :ok = BackgroundAgentJobs.complete_open_dispatch(job.id, agent.uid)

    from(row in Ankole.BackgroundAgentJobs.Schemas.Job, where: row.id == ^job.id)
    |> Repo.update_all(
      set: [
        status: "succeeded",
        attempts: 3,
        runtime_thread_id: "thread-settled-resume",
        completed_at: DateTime.utc_now(:microsecond)
      ]
    )

    assert {:ok, %{job: %{status: "queued"}}} =
             BackgroundAgentJobs.request_steer(job.id, %{
               "agent_uid" => agent.uid,
               "text" => "Continue in the same session.",
               "request_id" => "settled-resume"
             })

    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.utc_now(:microsecond),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_start = turn_start_payload!(envelope)
    assert decoded_request_context(turn_start)["attempts"] == 4

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "running"
    assert persisted.attempts == 4
    assert persisted.runtime_thread_id == "thread-settled-resume"
  end

  test "Turn checkpoints accept identical retries and reject divergent equal revisions" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "turn-revision")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200

    assert {:ok, turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(turn_start_payload!(envelope).turn)

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).attempts == 1

    now = DateTime.utc_now(:microsecond)

    attrs = %{
      "attempt" => 1,
      "runtime_thread_id" => "thread-revision",
      "runtime_turn_id" => "turn-revision",
      "kind" => "agent",
      "status" => "in_progress",
      "revision" => 0,
      "trajectory" => %{
        "format" => "ankole_chatml",
        "version" => 1,
        "messages" => [%{"role" => "user", "content" => "Original task"}]
      },
      "progress" => empty_turn_progress(),
      "usage" => nil,
      "error" => %{},
      "started_at" => now
    }

    assert {:ok, first} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               attrs,
               turn_ref,
               route
             )

    assert {:ok, retried} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               attrs,
               turn_ref,
               route
             )

    assert retried.id == first.id

    divergent =
      put_in(
        attrs,
        ["trajectory", "messages"],
        [%{"role" => "user", "content" => "Different payload at the same revision"}]
      )

    assert {:error, :background_agent_job_turn_revision_conflict} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               divergent,
               turn_ref,
               route
             )
  end

  test "Turn checkpoints persist native Codex child threads under the root job" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "child-turn")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200

    assert {:ok, turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(turn_start_payload!(envelope).turn)

    assert {:ok, %{job: anchored}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-root"
             })

    assert anchored.runtime_thread_id == "thread-root"
    now = DateTime.utc_now(:microsecond)

    assert {:ok, child_turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => 1,
                 "runtime_thread_id" => "thread-child",
                 "runtime_turn_id" => "turn-child",
                 "kind" => "agent",
                 "status" => "completed",
                 "revision" => 0,
                 "trajectory" => %{
                   "format" => "ankole_chatml",
                   "version" => 1,
                   "messages" => [%{"role" => "assistant", "content" => "Challenge complete."}]
                 },
                 "progress" => empty_turn_progress(),
                 "usage" => nil,
                 "error" => %{},
                 "started_at" => now,
                 "completed_at" => now
               },
               turn_ref,
               route
             )

    assert child_turn.runtime_thread_id == "thread-child"
  end

  test "waiting for user releases the worker assignment and the agent running slot" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "waiting-releases-capacity")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200

    assert {:ok, turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(turn_start_payload!(envelope).turn)

    assert {:ok, %{job: %{status: "running"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               agent.uid,
               %{"status" => "running", "runtime_thread_id" => "thread-waiting"},
               turn_ref: turn_ref,
               worker_route: route
             )

    completed_at = DateTime.utc_now(:microsecond)

    assert {:ok, _turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => 1,
                 "runtime_thread_id" => "thread-waiting",
                 "runtime_turn_id" => "turn-waiting",
                 "kind" => "agent",
                 "status" => "interrupted",
                 "revision" => 0,
                 "trajectory" => %{
                   "format" => "ankole_chatml",
                   "version" => 1,
                   "messages" => [
                     %{"role" => "user", "content" => "Ask when information is missing."},
                     %{
                       "role" => "assistant",
                       "content" => "",
                       "metadata" => %{"status" => "pending_user_input"},
                       "tool_calls" => [
                         %{
                           "id" => "request-user-input",
                           "type" => "function",
                           "function" => %{
                             "name" => "request_user_input",
                             "arguments" => ~s({"questions":[]})
                           }
                         }
                       ]
                     }
                   ]
                 },
                 "progress" => empty_turn_progress(),
                 "usage" => nil,
                 "error" => %{"code" => "request_user_input"},
                 "started_at" => completed_at,
                 "completed_at" => completed_at
               },
               turn_ref,
               route
             )

    assert {:ok, %{job: waiting}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               agent.uid,
               %{
                 "status" => "waiting_on_user",
                 "metadata" => %{"pending_user_input" => %{"questions" => []}}
               },
               turn_ref: turn_ref,
               worker_route: route
             )

    assert waiting.status == "waiting_on_user"

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(
               turn_noop_completed_payload(
                 turn_start_payload!(envelope).turn,
                 "background_agent_job_committed"
               )
             )

    assert %ActorSessionWorkerAssignment{status: "released"} =
             Repo.get_by!(ActorSessionWorkerAssignment,
               agent_uid: agent.uid,
               session_id: actor_key.session_id
             )

    assert Ankole.BackgroundAgentJobs.Schemas.Job.running_statuses() == ["running"]
  end

  test "active BackgroundAgentJob steering stays durable until Codex accepts it and the turn commits" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "durable-steer")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, turn_start_envelope}, 200
    turn_ref = turn_start_payload!(turn_start_envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

    assert {:ok, %{command_event: steer_event}} =
             BackgroundAgentJobs.request_steer(job.id, %{
               "agent_uid" => agent.uid,
               "text" => "Include the operator runbook.",
               "request_id" => "durable-steer"
             })

    assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(now, 1, :second)
             )

    assert_receive {:actor_lane, mailbox_envelope}, 200
    mailbox = envelope_body!(mailbox_envelope, :mailbox_updated)
    assert Repo.get!(Ankole.SignalsGateway.ActorEvent, steer_event.id).completed_at == nil

    assert %Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery{state: "sent"} =
             Repo.get_by!(Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery,
               actor_event_id: steer_event.id
             )

    assert {:ok, status_turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(turn_ref)

    assert {:ok, %{job: %{status: "running"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               agent.uid,
               %{"status" => "running", "runtime_thread_id" => "thread-durable-steer"},
               turn_ref: status_turn_ref,
               worker_route: route
             )

    assert {:error, :background_agent_job_pending_steer} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               agent.uid,
               %{"status" => "succeeded", "result" => %{"summary" => "Done"}},
               turn_ref: status_turn_ref,
               worker_route: route
             )

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status ==
             "running"

    assert {:ok,
            [%Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery{state: "accepted"}]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(mailbox.turn))

    completed_at = DateTime.utc_now(:microsecond)

    assert {:ok, _turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => 1,
                 "runtime_thread_id" => "thread-durable-steer",
                 "runtime_turn_id" => "turn-durable-steer",
                 "kind" => "agent",
                 "status" => "completed",
                 "revision" => 0,
                 "trajectory" => %{
                   "format" => "ankole_chatml",
                   "version" => 1,
                   "messages" => [
                     %{"role" => "user", "content" => "Complete the delegated task."},
                     %{"role" => "assistant", "content" => "Done"}
                   ]
                 },
                 "progress" => empty_turn_progress(),
                 "usage" => nil,
                 "error" => %{},
                 "started_at" => completed_at,
                 "completed_at" => completed_at
               },
               status_turn_ref,
               route
             )

    assert {:ok, %{job: %{status: "succeeded"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               agent.uid,
               %{"status" => "succeeded", "result" => %{"summary" => "Done"}},
               turn_ref: status_turn_ref,
               worker_route: route
             )

    assert :ok = WorkerRouteAuth.authorize_turn_route(status_turn_ref, route, :write)

    assert %ActorSessionWorkerAssignment{status: "assigned"} =
             Repo.get_by!(ActorSessionWorkerAssignment,
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(job.id)
             )

    assert Repo.get!(Ankole.SignalsGateway.ActorEvent, steer_event.id).completed_at == nil

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(
               turn_noop_completed_payload(turn_ref, "background_agent_job_committed")
             )

    assert %ActorSessionWorkerAssignment{status: "released"} =
             Repo.get_by!(ActorSessionWorkerAssignment,
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(job.id)
             )

    assert %DateTime{} = Repo.get!(Ankole.SignalsGateway.ActorEvent, steer_event.id).completed_at
  end

  test "a superseded worker cannot commit terminal status or release the recovery assignment" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    stale_route = unique_route()
    live_route = unique_route()
    :ok = Broker.register_local_worker(stale_route, self())
    on_exit(fn -> Broker.unregister_local_worker(stale_route) end)
    assert {:ok, stale_worker} = admit_worker(stale_route)

    job = create_job!(agent.uid, "late-worker-status")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    first_now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: first_now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, first_envelope}, 200
    first_turn_wire = turn_start_payload!(first_envelope).turn

    assert {:ok, stale_turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(first_turn_wire)

    assert :ok = WorkerRouteAuth.authorize_turn_route(stale_turn_ref, stale_route, :write)

    Repo.update_all(
      from(worker in Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker,
        where: worker.worker_id == ^stale_worker.worker_id
      ),
      set: [last_worker_heartbeat_at: DateTime.add(first_now, -120, :second)]
    )

    assert {:ok, %Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker{status: "stale"}} =
             ActorRuntime.mark_worker_stale_if_due(stale_worker.worker_id,
               now: first_now,
               stale_after_seconds: 60
             )

    :ok = Broker.register_local_worker(live_route, self())
    on_exit(fn -> Broker.unregister_local_worker(live_route) end)
    assert {:ok, live_worker} = admit_worker(live_route)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(first_now, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, second_envelope}, 200
    assert decoded_request_context(turn_start_payload!(second_envelope))["attempts"] == 2

    assert {:error, :worker_not_assigned_to_turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{},
               stale_turn_ref,
               stale_route
             )

    assert BackgroundAgentJobs.list_turns(job.id) == []

    assert {:error, :worker_not_assigned_to_turn} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               agent.uid,
               %{"status" => "succeeded", "result" => %{"summary" => "Too late"}},
               turn_ref: stale_turn_ref,
               worker_route: stale_route
             )

    assert %{status: "running", attempts: 2} =
             BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)

    assert %ActorSessionWorkerAssignment{worker_id: worker_id, status: "assigned"} =
             Repo.get_by!(ActorSessionWorkerAssignment,
               agent_uid: agent.uid,
               session_id: actor_key.session_id,
               status: "assigned"
             )

    assert worker_id == live_worker.worker_id
  end

  test "a failed active steer is replayed through its owner after the recovery turn commits" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "replay-steer")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, first_turn_envelope}, 200
    first_turn_ref = turn_start_payload!(first_turn_envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(first_turn_ref))

    assert {:ok, %{job: anchored}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-existing"
             })

    assert anchored.runtime_thread_id == "thread-existing"

    assert {:ok, %{command_event: steer_event}} =
             BackgroundAgentJobs.request_steer(job.id, %{
               "agent_uid" => agent.uid,
               "text" => "Preserve the rollback instructions.",
               "answers" => %{"risk" => "Low"},
               "request_id" => "replay-steer"
             })

    assert {:ok, %{status: :active_steer_nudged}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(now, 1, :second)
             )

    assert_receive {:actor_lane, _mailbox_envelope}, 200

    failure_time = DateTime.add(now, 2, :second)

    assert {:ok, %{status: :turn_failed, retry_available_at: retry_at}} =
             ActorRuntime.handle_turn_error(
               turn_error_payload(
                 first_turn_ref,
                 "worker_turn_failed",
                 "Background Agent Job steer delivery failed",
                 %{
                   "error_code" => "background_agent_job_steer_delivery_failed",
                   "retryable" => true
                 }
               ),
               now: failure_time
             )

    assert Repo.get!(Ankole.SignalsGateway.ActorEvent, steer_event.id).completed_at == nil

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: retry_at,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, recovery_envelope}, 200
    recovery = turn_start_payload!(recovery_envelope)

    assert decoded_request_context(recovery)["attempts"] == 2
    refute Map.has_key?(decoded_request_context(recovery), "pending_steering")

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).runtime_thread_id ==
             "thread-existing"

    assert_receive {:actor_lane, replay_envelope}, 200

    assert envelope_body!(replay_envelope, :mailbox_updated).actor_event.actor_event_id ==
             steer_event.id

    assert %Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery{
             state: "sent",
             attempt_no: 2,
             actor_event_id_fence: fence
           } =
             Repo.get_by!(Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery,
               actor_event_id: steer_event.id,
               attempt_no: 2
             )

    assert fence == recovery.turn.actor_event_id
  end

  test "worker placement deferral does not consume execution attempts or running slots" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "no-worker")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    Enum.reduce(1..4, job.queued_at, fn retry, now ->
      assert {:ok, %{status: :waiting_for_worker, reason: :worker_capacity}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: now,
                 lease_seconds: @long_lease_seconds
               )

      persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert persisted.status == "queued", "retry #{retry} must remain visibly queued"
      assert persisted.attempts == 0, "retry #{retry} must not consume an execution attempt"

      DateTime.add(now, 31, :second)
    end)
  end

  test "worker delivery failure requeues the job without consuming an attempt" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, _worker} = admit_worker(route)
    job = create_job!(agent.uid, "delivery-failure")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{status: :waiting_for_worker, reason: :worker_delivery}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "queued"
    assert persisted.attempts == 0
    assert persisted.started_at == nil
  end

  test "subscription accounts serialize Codex execution across agents" do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    auth_json =
      Ankole.JSON.encode!(%{
        "tokens" => %{"account_id" => "subscription-serial", "access_token" => "token"}
      })

    assert {:ok, account} =
             CodexAccounts.create_account(%{
               "name" => "Serial subscription",
               "auth_json" => auth_json
             })

    for agent <- [first_agent, second_agent] do
      assert {:ok, _result} =
               ModelProfiles.put_model_profile(agent.uid, "coding", %{
                 "codex_account_id" => account.account_id
               })
    end

    first = create_job!(first_agent.uid, "subscription-first")
    second = create_job!(second_agent.uid, "subscription-second")

    first_key = %{
      agent_uid: first_agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(first.id)
    }

    second_key = %{
      agent_uid: second_agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(second.id)
    }

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(first_key,
               now: DateTime.add(first.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, first_envelope}, 200

    assert {:ok, %{status: :waiting_for_worker, reason: :codex_account_capacity}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key,
               now: DateTime.add(second.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    queued = BackgroundAgentJobs.get_job_for_agent(second.id, second_agent.uid)
    assert queued.status == "queued"
    assert queued.attempts == 0

    assert {:ok, turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(turn_start_payload!(first_envelope).turn)

    assert {:ok, %{job: stopped}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               first.id,
               first_agent.uid,
               %{"status" => "stopped"}
             )

    assert stopped.status == "stopped"

    assert {:ok, %{status: :waiting_for_worker, reason: :codex_account_capacity}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key,
               now: DateTime.add(second.queued_at, 31, :second),
               lease_seconds: @long_lease_seconds
             )

    assert {:ok, %{job: acknowledged}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               first.id,
               first_agent.uid,
               %{"status" => "stopped"},
               turn_ref: turn_ref,
               worker_route: route
             )

    assert acknowledged.status == "stopped"

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(
               turn_noop_completed_payload(
                 turn_start_payload!(first_envelope).turn,
                 "background_agent_job_stopped"
               )
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key,
               now: DateTime.add(second.queued_at, 62, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, _second_envelope}, 200
    assert BackgroundAgentJobs.get_job_for_agent(second.id, second_agent.uid).attempts == 1
  end

  test "worker placement applies the configurable job-only capacity" do
    %{principal: agent} = agent_fixture()
    definition = BackgroundAgentJobWorkerConfig.definition()
    :ok = BackgroundAgentJobWorkerConfig.ensure_registered()
    :ok = AppConfigure.delete_global(definition)
    on_exit(fn -> AppConfigure.delete_global(definition) end)
    assert {:ok, 1} = AppConfigure.put_global(definition, 1)

    first_route = unique_route()
    second_route = unique_route()
    assert {:ok, first_worker} = admit_worker(first_route)
    assert {:ok, second_worker} = admit_worker(second_route)

    assert {:ok, first_assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(Ecto.UUID.generate())
             })

    assert {:ok, second_assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(Ecto.UUID.generate())
             })

    assert first_assignment.worker_id == first_worker.worker_id
    assert second_assignment.worker_id == second_worker.worker_id
  end

  test "sticky worker placement revalidates worker before locking its assignment" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route, %{capacity: %{"available_turn_slots" => 4}})

    actor_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(Ecto.UUID.generate())
    }

    assert {:ok, first} = WorkerPool.assign_worker(actor_key)
    assert {:ok, second} = WorkerPool.assign_worker(actor_key)

    assert first.id == second.id
    assert second.worker_id == worker.worker_id
    assert second.status == "assigned"
  end

  test "worker job capacity deferral does not claim an execution attempt" do
    %{principal: agent} = agent_fixture()
    definition = BackgroundAgentJobWorkerConfig.definition()
    :ok = BackgroundAgentJobWorkerConfig.ensure_registered()
    :ok = AppConfigure.delete_global(definition)
    on_exit(fn -> AppConfigure.delete_global(definition) end)
    assert {:ok, 1} = AppConfigure.put_global(definition, 1)

    route = unique_route()
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, _assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(Ecto.UUID.generate())
             })

    job = create_job!(agent.uid, "worker-capacity")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{status: :waiting_for_worker, reason: :worker_capacity}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "queued"
    assert persisted.attempts == 0
    assert persisted.started_at == nil
  end

  test "per-agent capacity is claimed atomically with worker placement" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    jobs =
      for suffix <- ~w(one two three four) do
        create_job!(agent.uid, "agent-capacity-#{suffix}")
      end

    for {job, offset} <- Enum.with_index(Enum.take(jobs, 3), 1) do
      actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: DateTime.add(job.queued_at, offset, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, _envelope}, 200
      persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert persisted.status == "running"
      assert persisted.attempts == 1
    end

    fourth = List.last(jobs)

    fourth_actor_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(fourth.id)
    }

    assert {:ok, %{status: :waiting_for_worker, reason: :agent_capacity}} =
             ReadyEventProcessor.process_ready_event_for_actor(fourth_actor_key,
               now: DateTime.add(fourth.queued_at, 4, :second),
               lease_seconds: @long_lease_seconds
             )

    persisted = BackgroundAgentJobs.get_job_for_agent(fourth.id, agent.uid)
    assert persisted.status == "queued"
    assert persisted.attempts == 0

    refute Repo.get_by(ActorSessionWorkerAssignment,
             agent_uid: agent.uid,
             session_id: fourth_actor_key.session_id,
             status: "assigned"
           )
  end

  test "retryable Turn persistence failures exhaust job attempts with a parent wakeup" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)

    assert {:ok, _worker} =
             admit_worker(route, %{capacity: %{"available_turn_slots" => 9}})

    job = create_job!(agent.uid, "turn-persistence-exhaustion")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    retry_at =
      Enum.reduce(1..5, DateTime.add(job.queued_at, 1, :second), fn expected_attempt, ready_at ->
        assert {:ok, %{send_outcome: "sent_or_queued"}} =
                 ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                   now: ready_at,
                   lease_seconds: @long_lease_seconds
                 )

        assert_receive {:actor_lane, envelope}, 200
        turn_ref = turn_start_payload!(envelope).turn

        persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
        assert persisted.status == "running"
        assert persisted.attempts == expected_attempt

        failure_time = DateTime.add(ready_at, 1, :second)

        if expected_attempt == 5 do
          assert {:ok, active_turn_ref} =
                   Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(turn_ref)

          assert {:ok, _turn} =
                   BackgroundAgentJobs.upsert_turn_from_worker(
                     job.id,
                     agent.uid,
                     %{
                       "attempt" => expected_attempt,
                       "runtime_thread_id" => "thread-exhausted",
                       "runtime_turn_id" => "turn-exhausted",
                       "kind" => "agent",
                       "status" => "in_progress",
                       "revision" => 0,
                       "trajectory" => %{
                         "format" => "ankole_chatml",
                         "version" => 1,
                         "messages" => [%{"role" => "user", "content" => "Continue the task."}]
                       },
                       "progress" => empty_turn_progress(),
                       "usage" => nil,
                       "error" => %{},
                       "started_at" => failure_time
                     },
                     active_turn_ref,
                     route
                   )
        end

        assert {:ok, %{status: :turn_failed, retry_available_at: retry_available_at}} =
                 ActorRuntime.handle_turn_error(
                   turn_error_payload(
                     turn_ref,
                     "worker_turn_failed",
                     "Background Agent Job Turn persistence failed",
                     %{
                       "error_code" => "background_agent_job_turn_persistence_failed",
                       "retryable" => true
                     }
                   ),
                   now: failure_time
                 )

        retry_available_at
      end)

    assert {:ok, %{status: :attempts_exhausted, job: failed}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: retry_at,
               lease_seconds: @long_lease_seconds
             )

    assert failed.status == "failed"
    assert failed.error["code"] == "attempts_exhausted"

    exhausted_turn =
      Repo.get_by!(Ankole.BackgroundAgentJobs.Schemas.Turn,
        job_id: job.id,
        runtime_turn_id: "turn-exhausted"
      )

    assert exhausted_turn.status == "interrupted"
    assert exhausted_turn.error["code"] == "attempts_exhausted"

    assert Repo.get_by!(Ankole.SignalsGateway.ActorEvent,
             agent_uid: agent.uid,
             session_id: job.owner_session_id,
             type: "background_agent_job.failed"
           )
  end

  test "explicit Turn persistence rejection fails the job and wakes the parent atomically" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "turn-persistence-rejected")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_ref = turn_start_payload!(envelope).turn

    assert {:ok, active_turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(turn_ref)

    checkpoint_at = DateTime.utc_now(:microsecond)

    assert {:ok, _turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => 1,
                 "runtime_thread_id" => "thread-rejected",
                 "runtime_turn_id" => "turn-rejected",
                 "kind" => "agent",
                 "status" => "in_progress",
                 "revision" => 0,
                 "trajectory" => %{
                   "format" => "ankole_chatml",
                   "version" => 1,
                   "messages" => [%{"role" => "user", "content" => "Run the delegated task."}]
                 },
                 "progress" => empty_turn_progress(),
                 "usage" => nil,
                 "error" => %{},
                 "started_at" => checkpoint_at
               },
               active_turn_ref,
               route
             )

    assert {:ok,
            %{status: :background_agent_job_failed, background_agent_job_failure: %{job: failed}}} =
             ActorRuntime.handle_turn_error(
               turn_error_payload(
                 turn_ref,
                 "worker_turn_failed",
                 "Background Agent Job Turn persistence was rejected",
                 %{
                   "error_code" => "background_agent_job_turn_persistence_rejected",
                   "retryable" => false
                 }
               ),
               now: DateTime.add(now, 1, :second)
             )

    assert failed.status == "failed"
    assert failed.error["code"] == "turn_persistence_rejected"

    rejected_turn =
      Repo.get_by!(Ankole.BackgroundAgentJobs.Schemas.Turn,
        job_id: job.id,
        runtime_turn_id: "turn-rejected"
      )

    assert rejected_turn.status == "interrupted"
    assert rejected_turn.error["code"] == "turn_persistence_rejected"

    assert %DateTime{} =
             Repo.get!(Ankole.SignalsGateway.ActorEvent, turn_ref.actor_event_id).completed_at

    assert Repo.get_by!(Ankole.SignalsGateway.ActorEvent,
             agent_uid: agent.uid,
             session_id: job.owner_session_id,
             type: "background_agent_job.failed"
           )
  end

  test "running cancellation commits stopped before the fenced worker is interrupted" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "running-stop")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, turn_envelope}, 200
    turn_ref = turn_start_payload!(turn_envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

    assert {:ok, %{job: stopped, command_event: stop_event}} =
             BackgroundAgentJobs.request_stop(job.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:test",
               "reason" => "Stop the background task"
             })

    assert stopped.status == "stopped"
    assert stopped.metadata["cancel_requested_by"] == "operator:test"
    assert stop_event.type == "command.stop"

    assert {:ok, %{status: :command_consumed, command: "command.stop"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(now, 1, :second)
             )

    assert_receive {:actor_lane, stop_control}, 200
    assert envelope_body!(stop_control, :turn_control).command == "stop"

    assert envelope_body!(stop_control, :turn_control).turn.actor_event_id ==
             turn_ref.actor_event_id

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status ==
             "stopped"

    assert %DateTime{} =
             Repo.get!(Ankole.SignalsGateway.ActorEvent, turn_ref.actor_event_id).completed_at

    assert %DateTime{} = Repo.get!(Ankole.SignalsGateway.ActorEvent, stop_event.id).completed_at

    refute Repo.get_by(Ankole.SignalsGateway.OutboxEntry,
             source_actor_event_id: stop_event.id
           )
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "owner_session_id" => "owner-session-#{suffix}",
               "source_tool_call_id" => "tool-background-agent-job-#{suffix}",
               "title" => "Job #{suffix}",
               "task" => "Complete job #{suffix}.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "chat-#{suffix}"
               }
             })

    job
  end

  defp empty_turn_progress do
    %{
      "completed_items" => 0,
      "tool_calls" => 0,
      "tools_used" => [],
      "files_changed" => []
    }
  end
end
