defmodule Ankole.SignalsGateway.ActorRuntime.RuntimeDeadlineTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SubagentDelegations

  describe "exact runtime deadlines" do
    test "a new incarnation of the same worker releases accepted work immediately" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, worker} = admit_worker(route)

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
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, _first_envelope}

      assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => first_turn_ref}
               })

      assert {:ok, replacement} =
               admit_worker(route, %{
                 worker_id: worker.worker_id,
                 incarnation_id: "replacement-incarnation"
               })

      assert replacement.status == "ready"
      assert replacement.incarnation_id == "replacement-incarnation"
      assert Repo.get!(ActorEvent, input.id).input_state == "open"

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.one!(
                 from(delivery in ActorEventDelivery,
                   where: delivery.actor_event_id_fence == ^input.id
                 )
               )

      assert {:ok, %{turn_ref: second_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 2, :second))

      assert second_turn_ref["actor_event_id"] == input.id
      assert second_turn_ref["actor_epoch"] == first_turn_ref["actor_epoch"] + 1
      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"] == second_turn_ref
    end

    test "stale worker deadline supersedes one worker's turn and retries through another worker" do
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

      assert {:ok, %AgentComputerWorker{status: "stale"}} =
               ActorRuntime.mark_worker_stale_if_due(stale_worker.worker_id,
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
    end

    test "stale worker releases a subagent turn for durable resume on another worker" do
      %{principal: agent} = agent_fixture()
      stale_route = unique_route()
      live_route = unique_route()

      :ok = Broker.register_local_worker(stale_route, self())
      on_exit(fn -> Broker.unregister_local_worker(stale_route) end)

      assert {:ok, stale_worker} = admit_worker(stale_route)

      assert {:ok, %{delegation: delegation}} =
               SubagentDelegations.create_with_dispatch(%{
                 "agent_uid" => agent.uid,
                 "session_id" => "parent-session-subagent-stale",
                 "tool_call_id" => "tool-subagent-stale",
                 "title" => "Resume after worker loss",
                 "task" => "Finish the durable delegated task.",
                 "reply_route" => %{
                   "binding_name" => "bot",
                   "signal_channel_id" => "chat-subagent-stale"
                 }
               })

      actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
      first_now = DateTime.add(delegation.queued_at, 1, :second)

      Repo.update_all(
        from(worker in AgentComputerWorker, where: worker.worker_id == ^stale_worker.worker_id),
        set: [last_worker_heartbeat_at: DateTime.add(first_now, -120, :second)]
      )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: first_now,
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, first_envelope}
      assert first_envelope["body"]["turn_start"]["request_context"]["attempts"] == 1

      assert {:ok, %{delegation: running}} =
               SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
                 "status" => "running",
                 "runtime_thread_id" => "thread-durable-resume"
               })

      assert running.status == "running"

      assert {:ok, %AgentComputerWorker{status: "stale"}} =
               ActorRuntime.mark_worker_stale_if_due(stale_worker.worker_id,
                 now: first_now,
                 stale_after_seconds: 60
               )

      persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
      assert persisted.status == "running"
      assert persisted.runtime_thread_id == "thread-durable-resume"
      refute persisted.completed_at

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, _live_worker} = admit_worker(live_route)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: DateTime.add(first_now, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["request_context"]["attempts"] == 2

      retried = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
      assert retried.status == "running"
      assert retried.attempts == 2
      assert retried.runtime_thread_id == "thread-durable-resume"
    end

    test "stale worker delete deadline deletes only that worker" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      Repo.update_all(
        from(stored_worker in AgentComputerWorker, where: stored_worker.id == ^worker.id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %AgentComputerWorker{status: "stale"}} =
               ActorRuntime.mark_worker_stale_if_due(worker.worker_id,
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60
               )

      assert {:error, :worker_not_due} =
               ActorRuntime.delete_worker_if_due(worker.worker_id,
                 now: DateTime.add(@base_time, 121, :second),
                 stale_worker_ttl_seconds: 3_600
               )

      assert {:ok, %AgentComputerWorker{}} =
               ActorRuntime.delete_worker_if_due(worker.worker_id,
                 now: DateTime.add(@base_time, 3_721, :second),
                 stale_worker_ttl_seconds: 3_600
               )

      refute Repo.get(AgentComputerWorker, worker.id)
    end
  end
end
