defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobDispatchTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.Conversation
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

    assert {:ok, heavy_profile} = ModelProfiles.get_model_profile(agent.uid, "heavy")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: heavy_profile["provider_id"],
               model: "openai/gpt-5.4-nano",
               provider_options: %{"reasoningEffort" => "medium"}
             })

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
    assert turn_start.model_ref.profile == "coding"
    assert turn_start.model_ref.provider_id == heavy_profile["provider_id"]
    assert turn_start.model_ref.provider_kind == "openrouter"
    assert turn_start.model_ref.model == "openai/gpt-5.4-nano"

    assert turn_start.model_ref.provider_options_json ==
             Ankole.JSON.encode!(%{"reasoningEffort" => "medium"})

    assert is_binary(Ankole.Kernel.RuntimeFabric.encode_envelope(envelope))
    assert decoded_request_context(turn_start)["turn_mode"] == "background_agent_job"
    assert decoded_request_context(turn_start)["job_id"] == job.id
    assert decoded_request_context(turn_start)["owner_session_id"] == job.owner_session_id
    assert decoded_request_context(turn_start)["attempts"] == 1

    assert get_in(decoded_request_context(turn_start), ["model_ref", "model"]) ==
             "openai/gpt-5.4-nano"

    refute Repo.get_by(Conversation,
             subject_uid: agent.uid,
             conversation_key: actor_key.session_id
           )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "running"
    assert persisted.attempts == 1
  end

  test "a message cannot resume a settled job" do
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

    assert {:error, {:background_agent_job_message_status_invalid, "succeeded"}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "Continue in the same session.",
               "request_id" => "settled-resume"
             })

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "succeeded"
    assert persisted.attempts == 3
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
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(
               turn_start_payload!(envelope).turn
             )

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).attempts == 1

    now = DateTime.utc_now(:microsecond)

    attrs = %{
      "attempt" => 1,
      "runtime_thread_id" => "thread-revision",
      "runtime_turn_id" => "turn-revision",
      "kind" => "agent",
      "status" => "in_progress",
      "revision" => 0,
      "trajectory" => trajectory_header(),
      "trajectory_groups" =>
        trajectory_groups([%{"role" => "user", "content" => "Original task"}]),
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

    unsupported =
      put_in(
        attrs,
        ["trajectory", "messages"],
        [%{"role" => "user", "content" => "Different payload at the same revision"}]
      )

    assert {:error, :background_agent_job_trajectory_messages_unsupported} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               unsupported,
               turn_ref,
               route
             )

    divergent =
      put_in(
        attrs,
        ["trajectory_groups", Access.at(0), "messages"],
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
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(
               turn_start_payload!(envelope).turn
             )

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
                 "trajectory" => trajectory_header(),
                 "trajectory_groups" =>
                   trajectory_groups([
                     %{"role" => "assistant", "content" => "Challenge complete."}
                   ]),
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
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_proto(
               turn_start_payload!(envelope).turn
             )

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
                 "trajectory" => trajectory_header(),
                 "trajectory_groups" =>
                   trajectory_groups([
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
                   ]),
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
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "Include the operator runbook.",
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
                 "trajectory" => trajectory_header(),
                 "trajectory_groups" =>
                   trajectory_groups([
                     %{"role" => "user", "content" => "Complete the delegated task."},
                     %{"role" => "assistant", "content" => "Done"}
                   ]),
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
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "Preserve the rollback instructions.",
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

  test "credential sharing does not impose a local Job concurrency slot" do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

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

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key,
               now: DateTime.add(second.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, second_envelope}, 200
    assert turn_start_payload!(first_envelope).turn.actor.agent_uid == first_agent.uid
    assert turn_start_payload!(second_envelope).turn.actor.agent_uid == second_agent.uid
    assert BackgroundAgentJobs.get_job_for_agent(first.id, first_agent.uid).attempts == 1
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
               session_id: BackgroundAgentJobs.job_session_id(1000)
             })

    assert {:ok, second_assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: BackgroundAgentJobs.job_session_id(1001)
             })

    assert first_assignment.worker_id == first_worker.worker_id
    assert second_assignment.worker_id == second_worker.worker_id
  end

  test "live work pins every Session and Job for one Agent to its current worker" do
    %{principal: agent} = agent_fixture()
    first_route = unique_route()
    second_route = unique_route()
    :ok = Broker.register_local_worker(first_route, self())
    :ok = Broker.register_local_worker(second_route, self())

    on_exit(fn ->
      Broker.unregister_local_worker(first_route)
      Broker.unregister_local_worker(second_route)
    end)

    assert {:ok, first_worker} =
             admit_worker(first_route, %{capacity: %{"available_turn_slots" => 4}})

    assert {:ok, _second_worker} =
             admit_worker(second_route, %{capacity: %{"available_turn_slots" => 4}})

    first_job = create_job!(agent.uid, "agent-sticky-first")

    first_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(first_job.id)
    }

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(first_key,
               now: DateTime.add(first_job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, _first_envelope}, 200

    second_job = create_job!(agent.uid, "agent-sticky-second")

    second_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(second_job.id)
    }

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key,
               now: DateTime.add(second_job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, _second_envelope}, 200

    assert Repo.get_by!(ActorSessionWorkerAssignment,
             agent_uid: agent.uid,
             session_id: first_key.session_id,
             status: "assigned"
           ).worker_id == first_worker.worker_id

    assert Repo.get_by!(ActorSessionWorkerAssignment,
             agent_uid: agent.uid,
             session_id: second_key.session_id,
             status: "assigned"
           ).worker_id == first_worker.worker_id
  end

  test "a full pinned worker queues same-Agent work instead of spilling to another worker" do
    %{principal: agent} = agent_fixture()
    first_route = unique_route()
    second_route = unique_route()
    :ok = Broker.register_local_worker(first_route, self())
    :ok = Broker.register_local_worker(second_route, self())

    on_exit(fn ->
      Broker.unregister_local_worker(first_route)
      Broker.unregister_local_worker(second_route)
    end)

    assert {:ok, first_worker} =
             admit_worker(first_route, %{capacity: %{"available_turn_slots" => 1}})

    assert {:ok, second_worker} =
             admit_worker(second_route, %{capacity: %{"available_turn_slots" => 4}})

    first_job = create_job!(agent.uid, "agent-sticky-full-first")

    first_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(first_job.id)
    }

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(first_key,
               now: DateTime.add(first_job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, _first_envelope}, 200

    second_job = create_job!(agent.uid, "agent-sticky-full-second")

    second_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(second_job.id)
    }

    assert {:ok, %{status: :waiting_for_worker, reason: :worker_capacity}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key,
               now: DateTime.add(second_job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    refute Repo.get_by(ActorSessionWorkerAssignment,
             agent_uid: agent.uid,
             session_id: second_key.session_id,
             worker_id: second_worker.worker_id,
             status: "assigned"
           )

    assert Repo.get_by!(ActorSessionWorkerAssignment,
             agent_uid: agent.uid,
             session_id: first_key.session_id,
             status: "assigned"
           ).worker_id == first_worker.worker_id
  end

  test "sticky worker placement revalidates worker before locking its assignment" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route, %{capacity: %{"available_turn_slots" => 4}})

    actor_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(1000)
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
               session_id: BackgroundAgentJobs.job_session_id(1000)
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

  test "credential pool exhaustion returns the Job attempt and waits for the earliest recovery" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "credential-pool-exhausted")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    ready_at = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: ready_at,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_ref = turn_start_payload!(envelope).turn
    failure_time = DateTime.add(ready_at, 1, :second)
    pool_retry_at = DateTime.add(failure_time, 3_300, :second)

    assert {:ok,
            %{
              status: :background_agent_job_requeued,
              retry_available_at: ^pool_retry_at,
              background_agent_job_requeue: %{
                kind: :credential_pool_requeued,
                job: requeued
              }
            }} =
             ActorRuntime.handle_turn_error(
               turn_error_payload(
                 turn_ref,
                 "worker_turn_failed",
                 "AIGateway credential pool exhausted.",
                 %{
                   "error_code" => "credential_pool_exhausted",
                   "retryable" => true,
                   "retry_at" => DateTime.to_iso8601(pool_retry_at)
                 }
               ),
               now: failure_time
             )

    assert requeued.status == "queued"
    assert requeued.attempts == 0
    assert requeued.started_at == nil

    persisted_event = Repo.get!(Ankole.SignalsGateway.ActorEvent, turn_ref.actor_event_id)
    assert persisted_event.input_state == "open"
    assert persisted_event.available_at == pool_retry_at

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: pool_retry_at,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, retry_envelope}, 200
    assert decoded_request_context(turn_start_payload!(retry_envelope))["attempts"] == 1
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).attempts == 1
  end

  test "an unavailable pool without a recovery time consumes the normal Job retry budget" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "credential-pool-terminal")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    ready_at = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: ready_at,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_ref = turn_start_payload!(envelope).turn
    failure_time = DateTime.add(ready_at, 1, :second)
    expected_retry_at = DateTime.add(failure_time, 60, :second)

    assert {:ok, result} =
             ActorRuntime.handle_turn_error(
               turn_error_payload(
                 turn_ref,
                 "worker_turn_failed",
                 "AIGateway credential pool has no usable credentials.",
                 %{
                   "error_code" => "credential_pool_exhausted",
                   "retryable" => true
                 }
               ),
               now: failure_time
             )

    assert result.status == :turn_failed
    assert result.retry_available_at == expected_retry_at
    refute Map.has_key?(result, :turn_error_compensation)

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "running"
    assert persisted.attempts == 1

    persisted_event = Repo.get!(Ankole.SignalsGateway.ActorEvent, turn_ref.actor_event_id)
    assert persisted_event.input_state == "open"
    assert persisted_event.available_at == expected_retry_at
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
                       "trajectory" => trajectory_header(),
                       "trajectory_groups" =>
                         trajectory_groups([
                           %{"role" => "user", "content" => "Continue the task."}
                         ]),
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

        # Job sessions wait on the long retry ladder so the five-attempt
        # budget can ride out an upstream outage of a few hours.
        assert DateTime.diff(retry_available_at, failure_time, :second) ==
                 Enum.at([60, 600, 1_800, 3_600, 7_200], expected_attempt - 1)

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

  test "a non-retryable worker failure before Codex starts fails the job and wakes the parent" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "worker-setup-failed")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_ref = turn_start_payload!(envelope).turn

    assert {:ok,
            %{
              status: :background_agent_job_failed,
              dead_lettered?: true,
              background_agent_job_failure: %{job: failed}
            }} =
             ActorRuntime.handle_turn_error(
               turn_error_payload(
                 turn_ref,
                 "worker_turn_failed",
                 "Codex did not install Agent Plugin deep-research",
                 %{
                   "llm_error_kind" => "unknown",
                   "retryable" => false,
                   "runtime" => "bun"
                 }
               ),
               now: DateTime.add(now, 1, :second)
             )

    assert failed.status == "failed"
    assert failed.error["code"] == "worker_turn_failed"
    assert failed.error["summary"] == "Codex did not install Agent Plugin deep-research"
    assert failed.error["details"]["retryable"] == false

    failed_event = Repo.get!(Ankole.SignalsGateway.ActorEvent, turn_ref.actor_event_id)
    assert failed_event.input_state == "dead_letter"
    assert %DateTime{} = failed_event.completed_at

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
                 "trajectory" => trajectory_header(),
                 "trajectory_groups" =>
                   trajectory_groups([
                     %{"role" => "user", "content" => "Run the delegated task."}
                   ]),
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

  defp trajectory_header, do: %{"format" => "ankole_chatml", "version" => 1}

  defp trajectory_groups(messages) do
    [%{"position" => 0, "item_key" => "test:0", "messages" => messages}]
  end
end
