defmodule Ankole.SignalsGateway.ActorRuntime.SteerStopCommandTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.InputTombstone

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  describe "steer and stop commands" do
    test "inactive steer command starts a worker turn with the steer args" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer focus on risk", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_lane, envelope}
      assert %{"payload_json" => payload} = envelope["body"]["turn_start"]["actor_event"]
      assert get_in(payload, ["data", "command", "argsText"]) == "focus on risk"
      assert envelope["body"]["turn_start"]["turn"]["actor_event_id"] == steer_event.id
    end

    test "active steer is attached to the live turn and completed when mailbox update is sent" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]
      assert turn_ref["actor_event_id"] == input.id

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      run = start_aigateway_run_for_turn!(turn_ref)

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer change course", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      assert_receive {:actor_lane, mailbox_envelope}
      assert mailbox_envelope["body"]["type"] == "mailbox_updated"
      mailbox = mailbox_envelope["body"]["mailbox_updated"]
      assert mailbox["reason"] == "command.steer"
      refute Map.has_key?(mailbox, "inputs")
      assert mailbox["actor_event"]["actor_event_id"] == steer_event.id
      assert mailbox["actor_event"]["type"] == "command.steer"

      assert get_in(mailbox, ["actor_event", "payload_json", "data", "command", "argsText"]) ==
               "change course"

      input_id = input.id
      steer_event_id = steer_event.id

      assert {:ok,
              [
                %ActorEventDelivery{
                  state: "accepted",
                  actor_event_id: ^steer_event_id,
                  actor_event_id_fence: ^input_id
                }
              ]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => mailbox["turn"]}
               })

      assert %ActorEventDelivery{state: "accepted", actor_event_id_fence: ^input_id} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      complete_aigateway_turn!(mailbox["turn"], "PONG", run: run, wait_for_mirror: true)

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      live_states = ActorEventDelivery.live_states()

      refute Repo.exists?(
               from(delivery in ActorEventDelivery,
                 where: delivery.actor_event_id_fence == ^input_id,
                 where: delivery.state in ^live_states
               )
             )

      refute Repo.exists?(
               from(message in Message,
                 where: fragment("? \\? ?", message.metadata, "event_source")
               )
             )
    end

    test "active steer is completed even when the final response wins before mailbox acceptance" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      run = start_aigateway_run_for_turn!(turn_ref)

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer too late for current answer", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      assert_receive {:actor_lane, mailbox_envelope}
      assert mailbox_envelope["body"]["type"] == "mailbox_updated"
      mailbox = mailbox_envelope["body"]["mailbox_updated"]

      input_id = input.id

      assert %ActorEventDelivery{state: "sent", actor_event_id_fence: ^input_id} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      complete_aigateway_turn!(mailbox["turn"], "PONG", run: run, wait_for_mirror: true)

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)
    end

    test "late initial turn acceptance ignores newer active steer delivery revision" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer update before accept", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, mailbox_envelope}
      mailbox = mailbox_envelope["body"]["mailbox_updated"]

      assert {:ok, [%ActorEventDelivery{state: "accepted", actor_event_id: input_id}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      assert input_id == input.id

      assert %ActorEventDelivery{state: "sent"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      assert {:ok, [%ActorEventDelivery{state: "accepted", actor_event_id: steer_id}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => mailbox["turn"]}
               })

      assert steer_id == steer_event.id
    end

    test "steer starts a new turn when the activation's current event already completed" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      input
      |> ActorEvent.changeset(%{completed_at: DateTime.add(@base_time, 2, :second)})
      |> Repo.update!()

      assert %ActorEventDelivery{state: "accepted"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: input.id)

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer start fresh", explicit: true}),
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", turn_ref: steer_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

      assert steer_turn_ref["actor_event_id"] == steer_event.id

      assert_receive {:actor_lane, steer_envelope}
      assert steer_envelope["body"]["type"] == "turn_start"
      assert steer_envelope["body"]["turn_start"]["turn"]["actor_event_id"] == steer_event.id
    end

    test "stop command cancels active generation and writes command feedback" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      generating = start_aigateway_run_for_turn!(turn_ref)
      :ok = Ankole.AIGateway.subscribe(agent.uid, generating.conversation_id)

      %InputTombstone{}
      |> InputTombstone.changeset(%{
        agent_uid: agent.uid,
        binding_name: "bot",
        signal_channel_id: input.signal_channel_id,
        source_entry_id: input.source_entry_id,
        tombstoned_until: DateTime.add(@base_time, 1, :day)
      })
      |> Repo.insert!()

      assert {:ok, %{actor_event: stop_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/stop", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Stopped.",
                stop_control_outcomes: [%{send_outcome: "sent_or_queued"}]
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:ai_gateway_event, :response_failed, event}
      assert event.subject_uid == agent.uid
      assert event.conversation_id == generating.conversation_id
      assert event.response_id == "resp_#{generating.id}"
      assert event.metadata["actor_event_id"] == input.id
      assert event.payload.error["code"] == "command.stop"
      assert event.payload.error["stage"] == "actor_runtime_cancel"

      assert_receive {:actor_lane, stop_control}
      assert stop_control["body"]["turn_control"]["command"] == "stop"
      assert stop_control["body"]["turn_control"]["turn"]["actor_event_id"] == input.id

      assert %Message{status: "error", metadata: metadata} = Repo.get!(Message, generating.id)
      assert metadata["error"]["code"] == "command.stop"
      assert metadata["error"]["stage"] == "actor_runtime_cancel"

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, stop_event.id).completed_at

      input_id = input.id

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.one!(
                 from(delivery in ActorEventDelivery,
                   where: delivery.actor_event_id_fence == ^input_id
                 )
               )

      assert %OutboxEntry{payload: %{"text" => "Stopped."}} =
               Repo.one!(
                 from(outbox in OutboxEntry,
                   where: outbox.source_actor_event_id == ^stop_event.id
                 )
               )
    end

    test "stop command bypasses a reset barrier while a turn is running" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      generating = start_aigateway_run_for_turn!(turn_ref)

      assert {:ok, reset_event} =
               append_runtime_actor_event(agent.uid, input.session_id, "session.reset_due",
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{actor_event: stop_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/stop", explicit: true}),
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Stopped.",
                stop_control_outcomes: [%{send_outcome: "sent_or_queued"}]
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

      assert_receive {:actor_lane, stop_control}
      assert stop_control["body"]["turn_control"]["command"] == "stop"
      assert stop_control["body"]["turn_control"]["turn"]["actor_event_id"] == input.id

      assert %Message{status: "error"} = Repo.get!(Message, generating.id)
      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, stop_event.id).completed_at
      assert is_nil(Repo.get!(ActorEvent, reset_event.id).completed_at)

      assert %OutboxEntry{payload: %{"text" => "Stopped."}} =
               Repo.one!(
                 from(outbox in OutboxEntry,
                   where: outbox.source_actor_event_id == ^stop_event.id
                 )
               )
    end
  end
end
