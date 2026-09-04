defmodule Ankole.SignalsGateway.ActorRuntime.TurnSilentCompletionTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  describe "silent completion" do
    test "records the silent outcome without a Response and acknowledges a retry" do
      %{event: input, turn_ref: turn_ref} = start_accepted_turn()

      assert {:ok,
              %{
                status: :turn_completed,
                deleted_deliveries: 1,
                outboxes: %{attachments: [], clarify: nil, finals: []},
                activation: %ActorSessionActivation{} = activation
              }} = complete_turn_silent(turn_ref)

      assert activation.status == "active"
      assert is_nil(activation.current_actor_event_id)

      assert %ActorEvent{
               completed_at: %DateTime{},
               turn_outcome: "silent",
               final_response_id: nil
             } =
               Repo.get!(ActorEvent, input.id)

      refute_live_deliveries(input.id)

      assert {:ok, %{status: :already_completed}} = complete_turn_silent(turn_ref)

      assert {:error, :actor_turn_completion_conflict} =
               commit_turn_completion(turn_ref, "resp_#{Ecto.UUID.generate()}")
    end

    test "records the adopted Response of a silent turn and writes no reply" do
      %{event: input, turn_ref: turn_ref} = start_accepted_turn()
      final = complete_aigateway_turn!(turn_ref, "<silent_success/>")
      final_response_id = "resp_#{final.id}"

      assert {:ok,
              %{status: :turn_completed, outboxes: %{attachments: [], clarify: nil, finals: []}}} =
               complete_turn_silent(turn_ref, final_response_id)

      assert %ActorEvent{completed_at: %DateTime{}, turn_outcome: "silent"} =
               completed = Repo.get!(ActorEvent, input.id)

      assert completed.final_response_id == final_response_id

      refute Repo.exists?(
               from(entry in OutboxEntry, where: entry.source_actor_event_id == ^input.id)
             )

      assert {:ok, %{status: :already_completed}} =
               complete_turn_silent(turn_ref, final_response_id)

      assert {:error, :actor_turn_completion_conflict} = complete_turn_silent(turn_ref)

      assert {:error, :actor_turn_completion_conflict} =
               commit_turn_completion(turn_ref, final_response_id)
    end

    test "rejects a silent completion that names a Response outside this turn" do
      %{event: input, turn_ref: turn_ref} = start_accepted_turn()

      assert {:error, :not_found} =
               complete_turn_silent(turn_ref, "resp_#{Ecto.UUID.generate()}")

      assert {:error, :invalid_final_response_id} = complete_turn_silent(turn_ref, "resp_bad")

      assert %ActorEvent{completed_at: nil, turn_outcome: nil} = Repo.get!(ActorEvent, input.id)
    end

    test "marks active steer events complete when the accepted turn ends silently" do
      %{agent: agent, event: input} = start_accepted_turn()

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
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated

      mailbox = envelope_body!(mailbox_envelope, :mailbox_updated)
      assert mailbox.actor_event.actor_event_id == steer_event.id

      assert {:ok, [%ActorEventDelivery{state: "accepted", actor_event_id: steer_id}]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(mailbox.turn))

      assert steer_id == steer_event.id

      assert {:ok, %{status: :turn_completed, deleted_deliveries: 2, superseded_deliveries: 0}} =
               complete_turn_silent(mailbox.turn)

      assert %ActorEvent{completed_at: %DateTime{}, turn_outcome: "silent"} =
               Repo.get!(ActorEvent, input.id)

      assert %ActorEvent{completed_at: %DateTime{}, turn_outcome: nil} =
               Repo.get!(ActorEvent, steer_event.id)

      refute_live_deliveries(input.id)
    end

    test "keeps an unapplied active steer open when a silent completion consumes the applied prefix" do
      %{agent: agent, event: input, turn_ref: turn_ref} = start_accepted_turn()

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer stay quiet", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert is_nil(Repo.get!(ActorEvent, steer_event.id).completed_at)

      assert_receive {:actor_lane, mailbox_envelope}, 2_000
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated

      assert {:ok, %{status: :turn_completed, deleted_deliveries: 1, superseded_deliveries: 1}} =
               complete_turn_silent(turn_ref)

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert is_nil(Repo.get!(ActorEvent, steer_event.id).completed_at)

      assert %ActorEventDelivery{state: "superseded"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: steer_event.id)

      assert {:ok, %{turn_ref: next_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 4, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert next_turn_ref.actor_event_id == steer_event.id
      assert_receive {:actor_lane, next_envelope}, 2_000
      assert turn_start_payload!(next_envelope).turn.actor_event_id == steer_event.id
    end
  end

  defp start_accepted_turn do
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
    turn_ref = turn_start_payload!(envelope).turn

    assert %ActorEventDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

    assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

    %{agent: agent, event: input, turn_ref: turn_ref}
  end

  defp refute_live_deliveries(actor_event_id) do
    live_states = ActorEventDelivery.live_states()

    refute Repo.exists?(
             from(delivery in ActorEventDelivery,
               where: delivery.actor_event_id_fence == ^actor_event_id,
               where: delivery.state in ^live_states
             )
           )
  end
end
