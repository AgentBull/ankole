defmodule Ankole.ActorRuntime.DeliveryFenceTest do
  use Ankole.ActorRuntimeCase

  describe "delivery fences" do
    test "record_only input does not start an actor turn or emit PONG" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{status: :recorded}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: false}),
                 now: @base_time
               )

      assert {:ok, %{status: :idle}} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.aggregate(ActorEvent, :count) == 0
      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "future available_at actor event is not delivered before ready time" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert DateTime.compare(input.available_at, @base_time) == :gt

      assert {:ok, %{status: :idle}} = process_ready_events_once(now: @base_time)
      assert Repo.aggregate(ActorEventDelivery, :count) == 0
      assert Repo.aggregate(Message, :count) == 0
      assert Repo.get!(ActorEvent, input.id).input_state == "open"
    end

    test "no worker available leaves ready event open without creating generation artifacts" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:error, :no_worker_available} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorEvent, input.id).input_state == "open"
      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(ActorEventDelivery, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "route failure records send_failed delivery and leaves actor event open" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorEvent, input.id).input_state == "open"

      assert %ActorEventDelivery{state: "send_failed", send_outcome: "unknown_route"} =
               Repo.one!(from(delivery in ActorEventDelivery))

      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "route retry keeps the actor event open without materializing message rows" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      dead_route = unique_route()
      live_route = unique_route()

      assert {:ok, _worker} = admit_worker(dead_route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route", turn_ref: first_turn_ref}} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert first_turn_ref["actor_event_id"] == input.id
      assert Repo.get!(ActorEvent, input.id).input_state == "open"
      assert Repo.aggregate(Message, :count) == 0

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, _worker} = admit_worker(live_route)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 2, :second))

      assert Repo.aggregate(Message, :count) == 0

      assert_receive {:actor_lane, envelope}
      assert envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id

      deliveries =
        Repo.all(from(delivery in ActorEventDelivery, order_by: [asc: delivery.attempt_no]))

      assert Enum.map(deliveries, & &1.state) == ["sent"]
      assert Enum.map(deliveries, & &1.attempt_no) == [2]
    end

    test "ready actor key scan blocks ordinary events behind live session delivery" do
      %{principal: agent} = agent_fixture()
      session_id = "ready-scan-session"

      assert {:ok, live_event} =
               append_runtime_actor_event(agent.uid, session_id, "im.message.addressed",
                 now: @base_time
               )

      assert {:ok, _ordinary_event} =
               append_runtime_actor_event(agent.uid, session_id, "im.message.addressed",
                 now: DateTime.add(@base_time, 1, :second)
               )

      insert_live_delivery!(live_event)

      assert Actors.list_ready_actor_keys(DateTime.add(@base_time, 2, :second), 10) == []

      assert {:ok, _stop_event} =
               append_runtime_actor_event(agent.uid, session_id, "command.stop",
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert [%{agent_uid: agent_uid, session_id: ^session_id}] =
               Actors.list_ready_actor_keys(DateTime.add(@base_time, 4, :second), 10)

      assert agent_uid == agent.uid
    end

    test "next ready event finds live-turn commands past the first 100 queued events" do
      %{principal: agent} = agent_fixture()
      session_id = "deep-command-session"

      assert {:ok, live_event} =
               append_runtime_actor_event(agent.uid, session_id, "im.message.addressed",
                 now: @base_time
               )

      insert_live_delivery!(live_event)

      Enum.each(1..101, fn offset ->
        assert {:ok, _ordinary_event} =
                 append_runtime_actor_event(agent.uid, session_id, "im.message.addressed",
                   now: DateTime.add(@base_time, offset, :second)
                 )
      end)

      assert {:ok, stop_event} =
               append_runtime_actor_event(agent.uid, session_id, "command.stop",
                 now: DateTime.add(@base_time, 200, :second)
               )

      assert %ActorEvent{id: stop_id} =
               Actors.next_ready_event(
                 agent.uid,
                 session_id,
                 DateTime.add(@base_time, 201, :second),
                 live_delivery?: true
               )

      assert stop_id == stop_event.id
    end

    test "expired activation lease is failed before retrying a ready event" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      dead_route = unique_route()

      :ok = Broker.register_local_worker(dead_route, self())
      on_exit(fn -> Broker.unregister_local_worker(dead_route) end)
      assert {:ok, _worker} = admit_worker(dead_route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued", turn_ref: first_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 1
               )

      assert first_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, first_envelope}
      assert first_envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id
      assert Repo.get!(ActorEvent, input.id).input_state == "open"

      stale_message =
        insert_generating_ai_message_for_actor_event!(
          input,
          now: DateTime.add(@base_time, 1, :second)
        )

      assert {:ok, %{expired_activations: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 3, :second),
                 stale_after_seconds: 86_400,
                 lease_grace_seconds: 0
               )

      assert {:ok, %{send_outcome: "sent_or_queued", turn_ref: second_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 4, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert second_turn_ref["actor_event_id"] == input.id
      assert second_turn_ref["actor_epoch"] == 2

      assert Repo.get!(Message, stale_message.id).status == "error"

      assert Repo.get!(Message, stale_message.id).metadata["error"]["code"] ==
               "activation_lease_expired"

      activations =
        ActorSessionActivation
        |> order_by([activation], asc: activation.actor_epoch)
        |> Repo.all()

      assert Enum.map(activations, & &1.status) == ["failed", "active"]
      assert Enum.map(activations, & &1.actor_epoch) == [1, 2]

      assert_receive {:actor_lane, retry_envelope}
      assert retry_envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id

      assert ["sent"] =
               ActorEventDelivery
               |> where([delivery], delivery.actor_event_id_fence == ^input.id)
               |> order_by([delivery], asc: delivery.attempt_no)
               |> select([delivery], delivery.state)
               |> Repo.all()
    end

    test "worker capacity is used when assigning actor sessions" do
      %{principal: agent} = agent_fixture()
      full_route = unique_route()
      ready_route = unique_route()

      assert {:ok, _worker} =
               admit_worker(full_route, %{
                 capacity: %{"available_turn_slots" => 0},
                 load: %{"active_turns" => 1}
               })

      assert {:ok, ready_worker} =
               admit_worker(ready_route, %{
                 capacity: %{"available_turn_slots" => 1},
                 load: %{"active_turns" => 0}
               })

      assert {:ok, assignment} =
               ActorRuntime.assign_worker(%{
                 agent_uid: agent.uid,
                 session_id: "signal-channel:capacity"
               })

      assert assignment.worker_id == ready_worker.worker_id
      assert assignment.transport_route == ready_route
    end

    test "missing worker capacity is not treated as available" do
      %{principal: agent} = agent_fixture()
      unknown_route = unique_route()
      ready_route = unique_route()

      assert {:ok, _worker} =
               admit_worker(unknown_route, %{
                 capacity: %{},
                 load: %{}
               })

      assert {:ok, ready_worker} =
               admit_worker(ready_route, %{
                 capacity: %{"available_turn_slots" => 1},
                 load: %{"active_turns" => 0}
               })

      assert {:ok, assignment} =
               ActorRuntime.assign_worker(%{
                 agent_uid: agent.uid,
                 session_id: "signal-channel:missing-capacity"
               })

      assert assignment.worker_id == ready_worker.worker_id
      assert assignment.transport_route == ready_route
    end

    test "turn_error fails the current turn and keeps the input open for a new activation" do
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

      assert {:ok, %{turn_ref: first_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert first_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, first_envelope}
      assert %ActorEventDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      failure_time = DateTime.add(@base_time, 2, :second)

      assert {:ok, %{status: :turn_failed, retry_available_at: retry_available_at}} =
               ActorRuntime.handle_turn_error(
                 %{
                   "turn_error" => %{
                     "turn" => first_turn_ref,
                     "code" => "worker_loop_failed",
                     "message" => "worker loop failed",
                     "details_json" => %{"retryable" => true}
                   }
                 },
                 now: failure_time
               )

      assert retry_available_at == DateTime.add(failure_time, 2, :second)

      assert Repo.get!(ActorEvent, input.id).input_state == "open"
      assert is_nil(Repo.get!(ActorEvent, input.id).completed_at)

      assert Repo.one!(from(delivery in ActorEventDelivery, select: delivery.state)) ==
               "superseded"

      assert Repo.aggregate(OutboxEntry, :count) == 0

      assert {:ok, %{status: :idle}} =
               process_ready_events_once(
                 now: DateTime.add(failure_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert {:ok, %{turn_ref: second_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(failure_time, 2, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert second_turn_ref["actor_event_id"] == input.id
      assert second_turn_ref["actor_epoch"] == 2

      assert Repo.one!(
               from(message in Message, where: message.role == "user", select: count(message.id))
             ) == 0

      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["actor_epoch"] == 2
    end

    test "repeated worker turn_error dead-letters the poison event and releases the session" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: poison_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "poison", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{actor_event: next_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "after poison", explicit: true}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert {:ok, %{status: :turn_failed, actor_event: first_failed}} =
               fail_next_turn!(DateTime.add(@base_time, 2, :second))

      assert first_failed.id == poison_event.id
      assert Repo.get!(ActorEvent, poison_event.id).input_state == "open"

      assert {:ok, %{status: :turn_failed, actor_event: second_failed}} =
               fail_next_turn!(DateTime.add(@base_time, 3, :second))

      assert second_failed.id == poison_event.id
      assert Repo.get!(ActorEvent, poison_event.id).input_state == "open"

      assert {:ok, %{status: :turn_dead_lettered, actor_event: dead_lettered}} =
               fail_next_turn!(DateTime.add(@base_time, 4, :second))

      assert dead_lettered.id == poison_event.id

      stored_poison = Repo.get!(ActorEvent, poison_event.id)
      assert stored_poison.input_state == "dead_letter"
      assert is_nil(stored_poison.completed_at)
      assert %DateTime{} = stored_poison.dead_letter_at

      assert {:ok, %{turn_ref: next_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 5, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert next_turn_ref["actor_event_id"] == next_event.id
      assert_receive {:actor_lane, next_envelope}
      assert next_envelope["body"]["turn_start"]["turn"]["actor_event_id"] == next_event.id
    end

    test "retryable turn_error backs off without poisoning the event" do
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
                 group_entry(%{text: "transient", explicit: true}),
                 now: @base_time
               )

      retry_available_at =
        Enum.reduce(1..2, DateTime.add(@base_time, 2, :second), fn attempt, now ->
          assert {:ok, %{status: :turn_failed, retry_available_at: retry_available_at}} =
                   fail_next_turn!(now, retryable?: true)

          assert Repo.get!(ActorEvent, input.id).input_state == "open"
          assert is_nil(Repo.get!(ActorEvent, input.id).dead_letter_at)
          assert DateTime.compare(retry_available_at, now) == :gt

          assert {:ok, %{status: :idle}} =
                   process_ready_events_once(
                     now: DateTime.add(now, max(attempt, 1), :second),
                     lease_seconds: @long_lease_seconds
                   )

          retry_available_at
        end)

      assert {:ok,
              %{
                status: :turn_failed,
                dead_lettered?: false,
                retry_available_at: next_retry_available_at,
                actor_event: retried
              }} =
               fail_next_turn!(retry_available_at, retryable?: true)

      assert retried.id == input.id
      assert DateTime.compare(next_retry_available_at, retry_available_at) == :gt

      stored = Repo.get!(ActorEvent, input.id)
      assert stored.input_state == "open"
      assert is_nil(stored.dead_letter_at)
    end

    test "nested aigateway retryable turn_error details back off without poisoning the event" do
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
                 group_entry(%{text: "nested transient", explicit: true}),
                 now: @base_time
               )

      now = DateTime.add(@base_time, 2, :second)

      assert {:ok,
              %{
                status: :turn_failed,
                dead_lettered?: false,
                retry_available_at: retry_available_at
              }} =
               fail_next_turn!(now,
                 details_json: %{
                   "runtime" => "bun",
                   "aigateway" => %{
                     "code" => "upstream_response_failed",
                     "details_json" => %{"retryable" => true}
                   }
                 }
               )

      assert DateTime.compare(retry_available_at, now) == :gt

      stored = Repo.get!(ActorEvent, input.id)
      assert stored.input_state == "open"
      assert is_nil(stored.dead_letter_at)
    end

    test "retryable turn_error continues to release the session while backing off" do
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
                 group_entry(%{text: "transient release", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{actor_event: next_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "after transient", explicit: true}),
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert {:ok, %{status: :turn_failed, retry_available_at: retry_available_at}} =
               fail_next_turn!(DateTime.add(@base_time, 2, :second), retryable?: true)

      assert Repo.get!(ActorEvent, input.id).input_state == "open"
      assert is_nil(Repo.get!(ActorEvent, input.id).dead_letter_at)
      assert DateTime.compare(retry_available_at, DateTime.add(@base_time, 2, :second)) == :gt

      assert {:ok, %{turn_ref: next_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 3, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert next_turn_ref["actor_event_id"] == next_event.id
    end

    test "context overflow turn_error marks the actor event for truncation retry" do
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

      assert {:ok, %{turn_ref: first_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert first_turn_ref["actor_event_id"] == input.id
      assert_receive {:actor_lane, first_envelope}
      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      assert {:ok, %{status: :turn_failed, actor_event: retried_event}} =
               ActorRuntime.handle_turn_error(%{
                 "turn_error" => %{
                   "turn" => first_turn_ref,
                   "code" => "worker_turn_failed",
                   "message" => "AIGateway stateful input exceeds the configured context budget.",
                   "details_json" => %{
                     "llm_error_kind" => "overflow",
                     "should_compress" => true,
                     "aigateway" => %{
                       "code" => "context_overflow",
                       "details_json" => %{
                         "reason" => "no_compaction_candidate",
                         "truncation" => "disabled"
                       }
                     }
                   }
                 }
               })

      assert retried_event.id == input.id

      stored = Repo.get!(ActorEvent, input.id)
      assert stored.input_state == "open"
      assert is_nil(stored.completed_at)
      assert get_in(stored.payload, ["data", "entry", "text"]) == "PING"
      assert get_in(stored.payload, ["data", "entry", "retry_reason"]) == "overflow_retry"
      assert get_in(stored.payload, ["data", "entry", "retry_of_actor_event_id"]) == input.id

      assert get_in(stored.payload, ["data", "entry", "overflow_retry", "details_json"]) ==
               %{
                 "llm_error_kind" => "overflow",
                 "should_compress" => true,
                 "aigateway" => %{
                   "code" => "context_overflow",
                   "details_json" => %{
                     "reason" => "no_compaction_candidate",
                     "truncation" => "disabled"
                   }
                 }
               }

      assert Repo.one!(from(delivery in ActorEventDelivery, select: delivery.state)) ==
               "superseded"

      assert {:ok, %{turn_ref: second_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 2, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert second_turn_ref["actor_event_id"] == input.id
      assert second_turn_ref["actor_epoch"] == 2
    end

    test "expired activation rejects late worker completion without provider output" do
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

      assert {:ok, %{turn_ref: turn_ref_from_result}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert turn_ref_from_result["actor_event_id"] == input.id
      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref
                 }
               })

      Repo.update_all(
        from(activation in ActorSessionActivation,
          where: activation.activation_uid == ^turn_ref["activation_uid"]
        ),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)]
      )

      assert {:error, :activation_lease_expired} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => turn_ref,
                   "reason" => "late_worker_completion"
                 }
               })

      assert Repo.get!(ActorEvent, input.id).input_state == "open"
      assert is_nil(Repo.get!(ActorEvent, input.id).completed_at)
      assert Repo.aggregate(Message, :count) == 0

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "worker progress extends the matching in-flight activation lease" do
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

      assert {:ok, %{turn_ref: turn_ref_from_result}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 2
               )

      assert turn_ref_from_result["actor_event_id"] == input.id
      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref
                 }
               })

      now = DateTime.utc_now(:microsecond)
      soon = DateTime.add(now, 1, :second)

      Repo.update_all(
        from(activation in ActorSessionActivation,
          where: activation.activation_uid == ^turn_ref["activation_uid"]
        ),
        set: [lease_expires_at: soon]
      )

      assert {:ok, activation} =
               ActorRuntime.handle_worker_progress(
                 %{
                   "worker_progress" => %{
                     "turn" => turn_ref,
                     "kind" => "checkpoint",
                     "summary" => "turn in progress"
                   }
                 },
                 now: now,
                 lease_seconds: 300
               )

      assert DateTime.compare(activation.lease_expires_at, DateTime.add(now, 299, :second)) ==
               :gt

      assert DateTime.compare(activation.last_actor_heartbeat_at, now) == :eq
    end
  end

  defp insert_live_delivery!(%ActorEvent{} = event) do
    %ActorEventDelivery{}
    |> ActorEventDelivery.changeset(%{
      actor_event_id: event.id,
      agent_uid: event.agent_uid,
      session_id: event.session_id,
      queue_sequence: event.queue_sequence,
      attempt_no: 1,
      actor_lane_message_id: "lane-#{event.id}",
      activation_uid: "activation-#{event.id}",
      actor_epoch: 1,
      actor_event_id_fence: event.id,
      revision: 0,
      state: "accepted",
      error: %{}
    })
    |> Repo.insert!()
  end

  defp fail_next_turn!(now, opts \\ []) do
    assert {:ok, %{turn_ref: turn_ref_from_result}} =
             process_ready_events_once(
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 2_000
    turn_ref = envelope["body"]["turn_start"]["turn"]
    assert turn_ref["actor_event_id"] == turn_ref_from_result["actor_event_id"]

    details_json =
      Keyword.get_lazy(opts, :details_json, fn ->
        if Keyword.get(opts, :retryable?, false) do
          %{"retryable" => true}
        else
          %{}
        end
      end)

    ActorRuntime.handle_turn_error(
      %{
        "turn_error" => %{
          "turn" => turn_ref,
          "code" => "worker_loop_failed",
          "message" => "worker loop failed",
          "details_json" => details_json
        }
      },
      now: now
    )
  end
end
