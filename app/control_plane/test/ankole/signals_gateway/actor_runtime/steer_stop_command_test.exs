defmodule Ankole.SignalsGateway.ActorRuntime.SteerStopCommandTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.I18n
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle

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
      payload = decoded_json_bytes(turn_start_payload!(envelope).actor_event.payload_json)
      assert get_in(payload, ["data", "command", "argsText"]) == "focus on risk"
      assert turn_start_payload!(envelope).turn.actor_event_id == steer_event.id
    end

    test "a turn start immediately drains steer persisted before its delivery existed" do
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
                 group_entry(%{text: "start work", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer use the correction", explicit: true}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      process_at = DateTime.add(@base_time, 2, :second)

      assert {:ok, %{turn_ref: initial_turn}} =
               process_ready_events_once(
                 now: process_at,
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, turn_envelope}, 2_000
      assert envelope_body_type(turn_envelope) == :turn_start
      assert_receive {:actor_lane, mailbox_envelope}, 2_000
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated

      assert initial_turn.actor_event_id == input.id
      assert envelope_body!(mailbox_envelope, :mailbox_updated).turn.actor_event_id == input.id

      assert envelope_body!(mailbox_envelope, :mailbox_updated).turn.revision ==
               initial_turn.revision + 1

      assert envelope_body!(mailbox_envelope, :mailbox_updated).actor_event.actor_event_id ==
               steer_event.id

      assert %ActorEventDelivery{state: "sent", actor_event_id_fence: input_id} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      assert input_id == input.id
    end

    test "active steer switches the card owner only after the worker accepts it" do
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
      turn_ref = turn_start_payload!(envelope).turn
      assert turn_ref.actor_event_id == input.id

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      run = start_aigateway_run_for_turn!(turn_ref)

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer change course", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      test_process = self()

      continue_reply_preview = fn stream_actor_event_id, new_owner ->
        send(
          test_process,
          {:reply_preview_handoff, stream_actor_event_id, new_owner.id}
        )

        :ok
      end

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"} = result} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 3, :second),
                 continue_reply_preview_fun: continue_reply_preview
               )

      refute Map.has_key?(result, :reply_preview_handoff)
      refute Repo.get!(ActorEvent, steer_event.id).completed_at
      refute_receive {:reply_preview_handoff, _input_id, _steer_event_id}
      assert_receive {:actor_lane, mailbox_envelope}
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated
      mailbox = envelope_body!(mailbox_envelope, :mailbox_updated)
      assert mailbox.reason == "command.steer"
      refute Map.has_key?(mailbox, "inputs")
      assert mailbox.actor_event.actor_event_id == steer_event.id
      assert mailbox.actor_event.type == "command.steer"

      assert get_in(decoded_json_bytes(mailbox.actor_event.payload_json), [
               "data",
               "command",
               "argsText"
             ]) ==
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
               TurnLifecycle.handle_turn_accepted(turn_accepted_payload(mailbox.turn),
                 continue_reply_preview_fun: continue_reply_preview
               )

      assert_receive {:reply_preview_handoff, ^input_id, ^steer_event_id}

      assert %ActorEventDelivery{state: "accepted", actor_event_id_fence: ^input_id} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
               TurnLifecycle.handle_turn_accepted(turn_accepted_payload(mailbox.turn),
                 continue_reply_preview_fun: continue_reply_preview
               )

      assert_receive {:reply_preview_handoff, ^input_id, ^steer_event_id}

      complete_aigateway_turn!(mailbox.turn, "PONG", run: run, wait_for_mirror: true)

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
      turn_ref = turn_start_payload!(envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

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

      refute Repo.get!(ActorEvent, steer_event.id).completed_at

      assert_receive {:actor_lane, mailbox_envelope}
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated
      mailbox = envelope_body!(mailbox_envelope, :mailbox_updated)

      input_id = input.id

      assert %ActorEventDelivery{state: "sent", actor_event_id_fence: ^input_id} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      complete_aigateway_turn!(mailbox.turn, "PONG", run: run, wait_for_mirror: true)

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)
    end

    test "a steer stays open for the next turn when the current turn finishes first" do
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
      turn_ref = turn_start_payload!(envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      run = start_aigateway_run_for_turn!(turn_ref)

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer use this next", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, mailbox_envelope}
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated
      mailbox = envelope_body!(mailbox_envelope, :mailbox_updated)

      complete_aigateway_turn!(turn_ref, "PONG", run: run, wait_for_mirror: true)

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      refute Repo.get!(ActorEvent, steer_event.id).completed_at

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      test_process = self()

      assert {:error, :sent_delivery_not_found} =
               TurnLifecycle.handle_turn_accepted(turn_accepted_payload(mailbox.turn),
                 continue_reply_preview_fun: fn stream_actor_event_id, new_owner ->
                   send(
                     test_process,
                     {:late_reply_preview_handoff, stream_actor_event_id, new_owner.id}
                   )

                   :ok
                 end
               )

      refute_receive {:late_reply_preview_handoff, _stream_actor_event_id, _new_owner_id}

      assert {:ok, %{send_outcome: "sent_or_queued", turn_ref: next_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

      assert next_turn_ref.actor_event_id == steer_event.id
      assert_receive {:actor_lane, next_turn_envelope}
      assert envelope_body_type(next_turn_envelope) == :turn_start
      assert turn_start_payload!(next_turn_envelope).turn.actor_event_id == steer_event.id
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
      turn_ref = turn_start_payload!(envelope).turn

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
      mailbox = envelope_body!(mailbox_envelope, :mailbox_updated)

      assert {:ok, [%ActorEventDelivery{state: "accepted", actor_event_id: input_id}]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      assert input_id == input.id

      assert %ActorEventDelivery{state: "sent"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      assert {:ok, [%ActorEventDelivery{state: "accepted", actor_event_id: steer_id}]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(mailbox.turn))

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
      turn_ref = turn_start_payload!(envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

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

      assert steer_turn_ref.actor_event_id == steer_event.id

      assert_receive {:actor_lane, steer_envelope}
      assert envelope_body_type(steer_envelope) == :turn_start
      assert turn_start_payload!(steer_envelope).turn.actor_event_id == steer_event.id
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
      turn_ref = turn_start_payload!(envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

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

      result =
        I18n.with_locale("zh-Hans-CN", fn ->
          process_ready_events_once(now: DateTime.add(@base_time, 3, :second))
        end)

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "已停止。",
                stop_control_outcomes: [%{send_outcome: "sent_or_queued"}]
              }} = result

      assert_receive {:ai_gateway_event, :response_failed, event}
      assert event.subject_uid == agent.uid
      assert event.conversation_id == generating.conversation_id
      assert event.response_id == "resp_#{generating.id}"
      assert event.metadata["actor_event_id"] == input.id
      assert event.payload.error["code"] == "command.stop"
      assert event.payload.error["stage"] == "actor_runtime_cancel"

      assert_receive {:actor_lane, stop_control}
      assert envelope_body!(stop_control, :turn_control).command == "stop"
      assert envelope_body!(stop_control, :turn_control).turn.actor_event_id == input.id

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

      assert %OutboxEntry{payload: %{"text" => "已停止。"}} =
               Repo.one!(
                 from(outbox in OutboxEntry,
                   where: outbox.source_actor_event_id == ^stop_event.id
                 )
               )
    end

    test "stop during an active steer cancels the fenced turn and supersedes both deliveries" do
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
      turn_ref = turn_start_payload!(envelope).turn
      assert turn_ref.actor_event_id == input.id

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      generating = start_aigateway_run_for_turn!(turn_ref)

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer change course", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, mailbox_envelope}
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated

      assert {:ok, %{actor_event: stop_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/stop", explicit: true}),
                 now: DateTime.add(@base_time, 4, :second)
               )

      assert {:ok, %{status: :command_consumed, feedback: "Stopped."}} =
               process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

      assert %Message{status: "error", metadata: metadata} = Repo.get!(Message, generating.id)
      assert metadata["error"]["code"] == "command.stop"
      assert metadata["error"]["stage"] == "actor_runtime_cancel"

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, stop_event.id).completed_at

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: input.id)

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)
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
      turn_ref = turn_start_payload!(envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

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
      assert envelope_body!(stop_control, :turn_control).command == "stop"
      assert envelope_body!(stop_control, :turn_control).turn.actor_event_id == input.id

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
