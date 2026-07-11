defmodule Ankole.SignalsGateway.ActorRuntime.SubagentDispatchTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.ActorRuntime.WorkerSubagentConfig
  alias Ankole.AppConfigure
  alias Ankole.SubagentDelegations

  test "dispatch starts a fenced non-conversation turn and increments attempts once" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "dispatch")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_start = envelope["body"]["turn_start"]
    assert turn_start["turn"]["actor"]["session_id"] == actor_key.session_id
    refute Map.has_key?(turn_start, "model_ref")
    assert is_binary(Ankole.Kernel.RuntimeFabric.encode_envelope(envelope))
    assert turn_start["request_context"]["turn_mode"] == "subagent_delegation"
    assert turn_start["request_context"]["delegation_id"] == delegation.id
    assert turn_start["request_context"]["parent_session_id"] == delegation.session_id
    assert turn_start["request_context"]["attempts"] == 1

    refute Repo.get_by(Conversation,
             subject_uid: agent.uid,
             conversation_key: actor_key.session_id
           )

    persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
    assert persisted.status == "running"
    assert persisted.attempts == 1
  end

  test "waiting for user releases the worker assignment and the agent running slot" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "waiting-releases-capacity")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(delegation.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200

    assert {:ok, turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_request(%{
               "turn" => envelope["body"]["turn_start"]["turn"]
             })

    assert {:ok, %{delegation: waiting}} =
             SubagentDelegations.commit_status_with_wakeup(
               delegation.id,
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
             ActorRuntime.handle_turn_noop_completed(%{
               "turn_noop_completed" => %{
                 "turn" => envelope["body"]["turn_start"]["turn"],
                 "reason" => "subagent_delegation_committed"
               }
             })

    assert %ActorSessionWorkerAssignment{status: "released"} =
             Repo.get_by!(ActorSessionWorkerAssignment,
               agent_uid: agent.uid,
               session_id: actor_key.session_id
             )

    assert Ankole.SubagentDelegations.Schemas.Delegation.running_statuses() == ["running"]
  end

  test "active subagent steering stays durable until Codex accepts it and the turn commits" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "durable-steer")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, turn_start_envelope}, 200
    turn_ref = turn_start_envelope["body"]["turn_start"]["turn"]

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(%{"turn_accepted" => %{"turn" => turn_ref}})

    assert {:ok, %{command_event: steer_event}} =
             SubagentDelegations.request_steer(delegation.id, %{
               "agent_uid" => agent.uid,
               "text" => "Include the operator runbook.",
               "request_id" => "durable-steer"
             })

    assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(now, 1, :second)
             )

    assert_receive {:actor_lane, mailbox_envelope}, 200
    mailbox = mailbox_envelope["body"]["mailbox_updated"]
    assert Repo.get!(Ankole.SignalsGateway.ActorEvent, steer_event.id).completed_at == nil

    assert %Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery{state: "sent"} =
             Repo.get_by!(Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery,
               actor_event_id: steer_event.id
             )

    assert {:ok, status_turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_request(%{"turn" => turn_ref})

    assert {:error, :subagent_pending_steer} =
             SubagentDelegations.commit_status_with_wakeup(
               delegation.id,
               agent.uid,
               %{"status" => "succeeded", "result" => %{"summary" => "Done"}},
               turn_ref: status_turn_ref,
               worker_route: route
             )

    assert SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid).status ==
             "running"

    assert {:ok,
            [%Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery{state: "accepted"}]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{"turn" => mailbox["turn"]}
             })

    assert {:ok, %{delegation: %{status: "succeeded"}}} =
             SubagentDelegations.commit_status_with_wakeup(
               delegation.id,
               agent.uid,
               %{"status" => "succeeded", "result" => %{"summary" => "Done"}},
               turn_ref: status_turn_ref,
               worker_route: route
             )

    assert :ok = WorkerRouteAuth.authorize_turn_route(status_turn_ref, route, :write)

    assert %ActorSessionWorkerAssignment{status: "assigned"} =
             Repo.get_by!(ActorSessionWorkerAssignment,
               agent_uid: agent.uid,
               session_id: "subagent:#{delegation.id}"
             )

    assert Repo.get!(Ankole.SignalsGateway.ActorEvent, steer_event.id).completed_at == nil

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(%{
               "turn_noop_completed" => %{
                 "turn" => turn_ref,
                 "reason" => "subagent_delegation_committed"
               }
             })

    assert %ActorSessionWorkerAssignment{status: "released"} =
             Repo.get_by!(ActorSessionWorkerAssignment,
               agent_uid: agent.uid,
               session_id: "subagent:#{delegation.id}"
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

    delegation = create_delegation!(agent.uid, "late-worker-status")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    first_now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: first_now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, first_envelope}, 200
    first_turn_wire = first_envelope["body"]["turn_start"]["turn"]

    assert {:ok, stale_turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_request(%{"turn" => first_turn_wire})

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
    assert second_envelope["body"]["turn_start"]["request_context"]["attempts"] == 2

    assert {:error, :worker_not_assigned_to_turn} =
             SubagentDelegations.append_worker_events(
               delegation.id,
               agent.uid,
               [
                 %{
                   "seq" => 0,
                   "direction" => "process",
                   "event_type" => "late_old_attempt",
                   "payload" => %{"must_not_persist" => true}
                 }
               ],
               stale_turn_ref,
               stale_route
             )

    assert SubagentDelegations.list_events(delegation.id) == []

    assert {:error, :worker_not_assigned_to_turn} =
             SubagentDelegations.commit_status_with_wakeup(
               delegation.id,
               agent.uid,
               %{"status" => "succeeded", "result" => %{"summary" => "Too late"}},
               turn_ref: stale_turn_ref,
               worker_route: stale_route
             )

    assert %{status: "running", attempts: 2} =
             SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)

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

    delegation = create_delegation!(agent.uid, "replay-steer")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, first_turn_envelope}, 200
    first_turn_ref = first_turn_envelope["body"]["turn_start"]["turn"]

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{"turn" => first_turn_ref}
             })

    assert {:ok, %{command_event: steer_event}} =
             SubagentDelegations.request_steer(delegation.id, %{
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
               %{
                 "turn_error" => %{
                   "turn" => first_turn_ref,
                   "code" => "worker_turn_failed",
                   "message" => "Subagent steer delivery failed",
                   "details_json" => %{
                     "error_code" => "subagent_steer_delivery_failed",
                     "retryable" => true
                   }
                 }
               },
               now: failure_time
             )

    assert Repo.get!(Ankole.SignalsGateway.ActorEvent, steer_event.id).completed_at == nil

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: retry_at,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, recovery_envelope}, 200
    recovery = recovery_envelope["body"]["turn_start"]

    assert recovery["request_context"]["attempts"] == 2
    refute Map.has_key?(recovery["request_context"], "pending_steering")

    assert_receive {:actor_lane, replay_envelope}, 200

    assert replay_envelope["body"]["mailbox_updated"]["actor_event"]["actor_event_id"] ==
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

    assert fence == recovery["turn"]["actor_event_id"]
  end

  test "worker placement deferral does not consume execution attempts or running slots" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "no-worker")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}

    Enum.reduce(1..4, delegation.queued_at, fn retry, now ->
      assert {:ok, %{status: :waiting_for_worker, reason: :worker_capacity}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: now,
                 lease_seconds: @long_lease_seconds
               )

      persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
      assert persisted.status == "queued", "retry #{retry} must remain visibly queued"
      assert persisted.attempts == 0, "retry #{retry} must not consume an execution attempt"

      DateTime.add(now, 31, :second)
    end)
  end

  test "worker delivery failure requeues the delegation without consuming an attempt" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, _worker} = admit_worker(route)
    delegation = create_delegation!(agent.uid, "delivery-failure")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}

    assert {:ok, %{status: :waiting_for_worker, reason: :worker_delivery}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(delegation.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
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

    first = create_delegation!(first_agent.uid, "subscription-first")
    second = create_delegation!(second_agent.uid, "subscription-second")
    first_key = %{agent_uid: first_agent.uid, session_id: "subagent:#{first.id}"}
    second_key = %{agent_uid: second_agent.uid, session_id: "subagent:#{second.id}"}

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

    queued = SubagentDelegations.get_delegation_for_agent(second.id, second_agent.uid)
    assert queued.status == "queued"
    assert queued.attempts == 0

    assert {:ok, turn_ref} =
             Ankole.SignalsGateway.ActorRuntime.TurnRef.from_request(%{
               "turn" => first_envelope["body"]["turn_start"]["turn"]
             })

    assert {:ok, %{delegation: stopped}} =
             SubagentDelegations.commit_status_with_wakeup(
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

    assert {:ok, %{delegation: acknowledged}} =
             SubagentDelegations.commit_status_with_wakeup(
               first.id,
               first_agent.uid,
               %{"status" => "stopped"},
               turn_ref: turn_ref,
               worker_route: route
             )

    assert acknowledged.status == "stopped"

    assert {:ok, %{status: :noop_completed}} =
             ActorRuntime.handle_turn_noop_completed(%{
               "turn_noop_completed" => %{
                 "turn" => first_envelope["body"]["turn_start"]["turn"],
                 "reason" => "subagent_stopped"
               }
             })

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(second_key,
               now: DateTime.add(second.queued_at, 62, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, _second_envelope}, 200
    assert SubagentDelegations.get_delegation_for_agent(second.id, second_agent.uid).attempts == 1
  end

  test "worker placement applies the configurable delegation-only capacity" do
    %{principal: agent} = agent_fixture()
    definition = WorkerSubagentConfig.definition()
    :ok = WorkerSubagentConfig.ensure_registered()
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
               session_id: "subagent:#{Ecto.UUID.generate()}"
             })

    assert {:ok, second_assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: "subagent:#{Ecto.UUID.generate()}"
             })

    assert first_assignment.worker_id == first_worker.worker_id
    assert second_assignment.worker_id == second_worker.worker_id
  end

  test "sticky worker placement revalidates worker before locking its assignment" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route, %{capacity: %{"available_turn_slots" => 4}})
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{Ecto.UUID.generate()}"}

    assert {:ok, first} = WorkerPool.assign_worker(actor_key)
    assert {:ok, second} = WorkerPool.assign_worker(actor_key)

    assert first.id == second.id
    assert second.worker_id == worker.worker_id
    assert second.status == "assigned"
  end

  test "worker delegation capacity deferral does not claim an execution attempt" do
    %{principal: agent} = agent_fixture()
    definition = WorkerSubagentConfig.definition()
    :ok = WorkerSubagentConfig.ensure_registered()
    :ok = AppConfigure.delete_global(definition)
    on_exit(fn -> AppConfigure.delete_global(definition) end)
    assert {:ok, 1} = AppConfigure.put_global(definition, 1)

    route = unique_route()
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, _assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: "subagent:#{Ecto.UUID.generate()}"
             })

    delegation = create_delegation!(agent.uid, "worker-capacity")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}

    assert {:ok, %{status: :waiting_for_worker, reason: :worker_capacity}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(delegation.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
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

    delegations =
      for suffix <- ~w(one two three four) do
        create_delegation!(agent.uid, "agent-capacity-#{suffix}")
      end

    for {delegation, offset} <- Enum.with_index(Enum.take(delegations, 3), 1) do
      actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: DateTime.add(delegation.queued_at, offset, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, _envelope}, 200
      persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
      assert persisted.status == "running"
      assert persisted.attempts == 1
    end

    fourth = List.last(delegations)
    fourth_actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{fourth.id}"}

    assert {:ok, %{status: :waiting_for_worker, reason: :agent_capacity}} =
             ReadyEventProcessor.process_ready_event_for_actor(fourth_actor_key,
               now: DateTime.add(fourth.queued_at, 4, :second),
               lease_seconds: @long_lease_seconds
             )

    persisted = SubagentDelegations.get_delegation_for_agent(fourth.id, agent.uid)
    assert persisted.status == "queued"
    assert persisted.attempts == 0

    refute Repo.get_by(ActorSessionWorkerAssignment,
             agent_uid: agent.uid,
             session_id: fourth_actor_key.session_id,
             status: "assigned"
           )
  end

  test "retryable audit infrastructure failures exhaust delegation attempts with a parent wakeup" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "audit-exhaustion")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}

    retry_at =
      Enum.reduce(1..3, DateTime.add(delegation.queued_at, 1, :second), fn expected_attempt,
                                                                           ready_at ->
        assert {:ok, %{send_outcome: "sent_or_queued"}} =
                 ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                   now: ready_at,
                   lease_seconds: @long_lease_seconds
                 )

        assert_receive {:actor_lane, envelope}, 200
        turn_ref = envelope["body"]["turn_start"]["turn"]

        persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
        assert persisted.status == "running"
        assert persisted.attempts == expected_attempt

        failure_time = DateTime.add(ready_at, 1, :second)

        assert {:ok, %{status: :turn_failed, retry_available_at: retry_available_at}} =
                 ActorRuntime.handle_turn_error(
                   %{
                     "turn_error" => %{
                       "turn" => turn_ref,
                       "code" => "worker_turn_failed",
                       "message" => "Subagent audit persistence failed",
                       "details_json" => %{
                         "error_code" => "subagent_audit_persistence_failed",
                         "retryable" => true
                       }
                     }
                   },
                   now: failure_time
                 )

        retry_available_at
      end)

    assert {:ok, %{status: :attempts_exhausted, delegation: failed}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: retry_at,
               lease_seconds: @long_lease_seconds
             )

    assert failed.status == "failed"
    assert failed.error["code"] == "attempts_exhausted"

    assert Repo.get_by!(Ankole.SignalsGateway.ActorEvent,
             agent_uid: agent.uid,
             session_id: delegation.session_id,
             type: "subagent.delegation.failed"
           )
  end

  test "explicit audit rejection fails the delegation and wakes the parent atomically" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "audit-rejected")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_ref = envelope["body"]["turn_start"]["turn"]

    assert {:ok, %{status: :subagent_failed, subagent_failure: %{delegation: failed}}} =
             ActorRuntime.handle_turn_error(
               %{
                 "turn_error" => %{
                   "turn" => turn_ref,
                   "code" => "worker_turn_failed",
                   "message" => "Subagent audit persistence was rejected",
                   "details_json" => %{
                     "error_code" => "subagent_audit_persistence_rejected",
                     "retryable" => false
                   }
                 }
               },
               now: DateTime.add(now, 1, :second)
             )

    assert failed.status == "failed"
    assert failed.error["code"] == "audit_persistence_rejected"

    assert %DateTime{} =
             Repo.get!(Ankole.SignalsGateway.ActorEvent, turn_ref["actor_event_id"]).completed_at

    assert Repo.get_by!(Ankole.SignalsGateway.ActorEvent,
             agent_uid: agent.uid,
             session_id: delegation.session_id,
             type: "subagent.delegation.failed"
           )
  end

  test "running cancellation commits stopped before the fenced worker is interrupted" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "running-stop")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, turn_envelope}, 200
    turn_ref = turn_envelope["body"]["turn_start"]["turn"]

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(%{"turn_accepted" => %{"turn" => turn_ref}})

    assert {:ok, %{delegation: stopped, command_event: stop_event}} =
             SubagentDelegations.request_stop(delegation.id, %{
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
    assert stop_control["body"]["turn_control"]["command"] == "stop"

    assert stop_control["body"]["turn_control"]["turn"]["actor_event_id"] ==
             turn_ref["actor_event_id"]

    assert SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid).status ==
             "stopped"

    assert %DateTime{} =
             Repo.get!(Ankole.SignalsGateway.ActorEvent, turn_ref["actor_event_id"]).completed_at

    assert %DateTime{} = Repo.get!(Ankole.SignalsGateway.ActorEvent, stop_event.id).completed_at

    refute Repo.get_by(Ankole.SignalsGateway.OutboxEntry,
             source_actor_event_id: stop_event.id
           )
  end

  defp create_delegation!(agent_uid, suffix) do
    assert {:ok, %{delegation: delegation}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "session_id" => "parent-session-#{suffix}",
               "tool_call_id" => "tool-subagent-#{suffix}",
               "title" => "Delegation #{suffix}",
               "prompt" => "Complete delegation #{suffix}.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "chat-#{suffix}"
               }
             })

    delegation
  end
end
