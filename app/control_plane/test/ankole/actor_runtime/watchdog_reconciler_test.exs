defmodule Ankole.ActorRuntime.WatchdogReconcilerTest do
  use Ankole.ActorRuntimeCase

  alias Ankole.CodexDelegations

  describe "watchdog and startup reconciler" do
    test "watchdog supersedes stale unaccepted delivery and retries through another worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      stale_route = unique_route()
      live_route = unique_route()

      :ok = Broker.register_local_worker(stale_route, self())
      on_exit(fn -> Broker.unregister_local_worker(stale_route) end)

      assert {:ok, stale_worker} = admit_worker(stale_route)

      Repo.update_all(
        from(worker in AgentComputerWorker, where: worker.worker_id == ^stale_worker.worker_id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{turn_ref: first_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 300
               )

      assert first_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, _first_envelope}
      assert %ActorEventDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      stale_message =
        insert_generating_ai_message_for_actor_event!(
          input,
          now: DateTime.add(@base_time, -400, :second)
        )

      assert {:ok, %{stale_workers: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60
               )

      assert Repo.get!(ActorEvent, input.id).input_state == "open"

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.one!(
                 from(delivery in ActorEventDelivery,
                   where: delivery.actor_event_id_fence == ^input.id
                 )
               )

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, live_worker} = admit_worker(live_route)

      assert {:ok, %{turn_ref: second_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 121, :second))

      assert second_turn_ref["actor_event_id"] == input.id

      assert Repo.get!(Message, stale_message.id).status == "error"

      assert Repo.get!(Message, stale_message.id).metadata["error"]["code"] ==
               "heartbeat_timeout"

      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id

      assert %ActorSessionActivation{
               assigned_worker_id: assigned_worker_id,
               current_actor_event_id: current_actor_event_id,
               status: "active"
             } =
               Repo.one!(
                 from(activation in ActorSessionActivation,
                   where: activation.status == "active"
                 )
               )

      assert assigned_worker_id == live_worker.worker_id
      assert current_actor_event_id == input.id

      assert Repo.exists?(
               from(activation in ActorSessionActivation,
                 where: activation.status == "failed"
               )
             )

      assert ["sent"] =
               ActorEventDelivery
               |> where([delivery], delivery.actor_event_id_fence == ^input.id)
               |> order_by([delivery], asc: delivery.attempt_no)
               |> select([delivery], delivery.state)
               |> Repo.all()
    end

    test "watchdog fails stale accepted worker turn and retries through another worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      stale_route = unique_route()
      live_route = unique_route()

      :ok = Broker.register_local_worker(stale_route, self())
      on_exit(fn -> Broker.unregister_local_worker(stale_route) end)

      assert {:ok, stale_worker} = admit_worker(stale_route)

      Repo.update_all(
        from(worker in AgentComputerWorker, where: worker.worker_id == ^stale_worker.worker_id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{turn_ref: first_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 300
               )

      assert first_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, _first_envelope}

      assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => first_turn_ref
                 }
               })

      stale_message = insert_generating_ai_message_for_actor_event!(input)

      assert {:ok, %{stale_workers: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60
               )

      assert Repo.get!(ActorEvent, input.id).input_state == "open"

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.one!(
                 from(delivery in ActorEventDelivery,
                   where: delivery.actor_event_id_fence == ^input.id
                 )
               )

      assert %Message{status: "error"} = Repo.get!(Message, stale_message.id)

      assert Repo.get!(Message, stale_message.id).metadata["error"]["code"] ==
               "heartbeat_timeout"

      assert %ActorSessionActivation{status: "failed"} =
               Repo.one!(from(activation in ActorSessionActivation))

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, live_worker} = admit_worker(live_route)

      assert {:ok, %{turn_ref: second_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 121, :second))

      assert second_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id

      assert %ActorSessionActivation{
               assigned_worker_id: assigned_worker_id,
               current_actor_event_id: current_actor_event_id,
               status: "active"
             } =
               Repo.one!(
                 from(activation in ActorSessionActivation,
                   where: activation.status == "active"
                 )
               )

      assert assigned_worker_id == live_worker.worker_id
      assert current_actor_event_id == input.id
    end

    test "watchdog fails Codex delegations owned by a stale worker route" do
      %{principal: agent} = agent_fixture()
      stale_route = unique_route()

      :ok = Broker.register_local_worker(stale_route, self())
      on_exit(fn -> Broker.unregister_local_worker(stale_route) end)

      assert {:ok, stale_worker} = admit_worker(stale_route)

      Repo.update_all(
        from(worker in AgentComputerWorker, where: worker.worker_id == ^stale_worker.worker_id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, create_envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "codex-stale-create",
                   "method" => "codex.delegation.create",
                   "payload_json" => %{
                     "agent_uid" => agent.uid,
                     "session_id" => "session-codex-stale",
                     "tool_call_id" => "tool-codex-stale"
                   }
                 },
                 stale_route
               )

      delegation_id = rpc_payload(create_envelope)["delegation_id"]

      assert {:ok, running_envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "codex-stale-running",
                   "method" => "codex.delegation.status.update",
                   "payload_json" => %{
                     "delegation_id" => delegation_id,
                     "agent_uid" => agent.uid,
                     "status" => "running"
                   }
                 },
                 stale_route
               )

      assert rpc_payload(running_envelope)["status"] == "running"

      assert CodexDelegations.get_delegation_for_agent(delegation_id, agent.uid).metadata[
               "worker_route"
             ] == stale_route

      assert {:ok, %{stale_codex_delegations: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60
               )

      delegation = CodexDelegations.get_delegation_for_agent(delegation_id, agent.uid)
      assert delegation.status == "failed"
      assert delegation.error["code"] == "owner_worker_stale"
      assert delegation.error["worker_route"] == stale_route
      assert delegation.completed_at
    end

    test "watchdog deletes stale worker projections after the v1 ttl" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      Repo.update_all(
        from(stored_worker in AgentComputerWorker, where: stored_worker.id == ^worker.id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %{stale_workers: 1, deleted_stale_workers: 0}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60,
                 stale_worker_ttl_seconds: 3_600
               )

      assert %AgentComputerWorker{status: "stale"} = Repo.get!(AgentComputerWorker, worker.id)

      assert {:ok, %{stale_workers: 0, deleted_stale_workers: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 3_700, :second),
                 stale_after_seconds: 60,
                 stale_worker_ttl_seconds: 3_600
               )

      refute Repo.get(AgentComputerWorker, worker.id)
    end

    test "projection loss reconciles old started turn and creates retry generation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{turn_ref: first_turn_ref_from_result}} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert first_turn_ref_from_result["actor_event_id"] == input.id
      assert_receive {:actor_lane, first_envelope}
      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      stale_message =
        insert_generating_ai_message_for_actor_event!(
          input,
          now: DateTime.add(@base_time, -400, :second)
        )

      Repo.delete_all(ActorEventDelivery)
      Repo.delete_all(ActorSessionActivation)

      assert {:ok, 1} =
               ActorRuntime.reconcile_projection_lost_started_turns(
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert Repo.get!(Message, stale_message.id).status == "error"

      assert Repo.get!(Message, stale_message.id).metadata["error"]["code"] ==
               "actor_runtime_projection_lost"

      assert Repo.get!(ActorEvent, input.id).input_state == "open"

      assert {:error, :actor_runtime_fence_not_found} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => first_turn_ref,
                   "reason" => "late_worker_completion"
                 }
               })

      assert {:ok, %{turn_ref: second_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert second_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id
    end

    test "reconciler runs a startup projection-loss pass" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{turn_ref: started_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert started_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, _envelope}

      insert_generating_ai_message_for_actor_event!(
        input,
        now: DateTime.add(@base_time, -400, :second)
      )

      Repo.delete_all(ActorEventDelivery)
      Repo.delete_all(ActorSessionActivation)

      start_supervised!({Reconciler, name: unique_process_name("reconciler")})

      assert %Message{status: "error"} = wait_for_ai_message_status(input.id, "error")
      assert Repo.get!(ActorEvent, input.id).input_state == "open"
    end
  end

  defp rpc_payload(envelope) do
    assert get_in(envelope, ["body", "type"]) == "rpc_response"
    get_in(envelope, ["body", "rpc_response", "payload_json"])
  end
end
