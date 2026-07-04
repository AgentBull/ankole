defmodule Ankole.ActorRuntime.TurnNoopCompletionTest do
  use Ankole.ActorRuntimeCase

  describe "turn_noop_completed" do
    test "marks an accepted actor event complete without writing output" do
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
                 group_entry(%{text: "observe only", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}, 2_000
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert %ActorEventDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref
                 }
               })

      assert {:ok, %{status: :noop_completed, deleted_deliveries: 1}} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => turn_ref,
                   "reason" => "ambient_silent"
                 }
               })

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at

      live_states = ActorEventDelivery.live_states()

      refute Repo.exists?(
               from(delivery in ActorEventDelivery,
                 where: delivery.actor_event_id == ^input.id,
                 where: delivery.state in ^live_states
               )
             )

      assert {:ok, %{status: :already_completed, deleted_deliveries: 0}} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => turn_ref,
                   "reason" => "ambient_silent"
                 }
               })
    end

    test "marks active steer events complete when the accepted turn ends as noop" do
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
                 group_entry(%{text: "observe only", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}, 2_000
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer stay quiet", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, mailbox_envelope}, 2_000
      assert mailbox_envelope["body"]["type"] == "mailbox_updated"

      assert mailbox_envelope["body"]["mailbox_updated"]["actor_event"]["actor_event_id"] ==
               steer_event.id

      mailbox = mailbox_envelope["body"]["mailbox_updated"]

      assert {:ok, [%ActorEventDelivery{state: "accepted", actor_event_id: steer_id}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => mailbox["turn"]}
               })

      assert steer_id == steer_event.id

      assert {:ok, %{status: :noop_completed, deleted_deliveries: 2, superseded_deliveries: 0}} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => turn_ref,
                   "reason" => "ambient_silent"
                 }
               })

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      live_states = ActorEventDelivery.live_states()

      refute Repo.exists?(
               from(delivery in ActorEventDelivery,
                 where: delivery.actor_event_id_fence == ^input.id,
                 where: delivery.state in ^live_states
               )
             )
    end

    test "keeps active steer completed when noop supersedes it before worker acceptance" do
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
                 group_entry(%{text: "observe only", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}, 2_000
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer stay quiet", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      assert_receive {:actor_lane, mailbox_envelope}, 2_000
      assert mailbox_envelope["body"]["type"] == "mailbox_updated"

      assert {:ok, %{status: :noop_completed, deleted_deliveries: 1, superseded_deliveries: 1}} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => turn_ref,
                   "reason" => "ambient_silent"
                 }
               })

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)
    end
  end
end
