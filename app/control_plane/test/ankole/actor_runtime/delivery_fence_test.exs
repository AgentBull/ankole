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
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(LlmTurn, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "future available_at actor input is not delivered before ready time" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert DateTime.compare(input.available_at, @base_time) == :gt

      assert {:ok, %{status: :idle}} = ActorRuntime.process_ready_inputs_once(now: @base_time)
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.aggregate(LlmTurn, :count) == 0
      assert Repo.get!(ActorInput, input.id).input_state == "open"
    end

    test "no worker available leaves ready input open without creating generation artifacts" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:error, :no_worker_available} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorInput, input.id).input_state == "open"
      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(LlmTurn, :count) == 0
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "route failure records send_failed delivery and leaves actor input open" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route"}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert %ActorInputDelivery{state: "send_failed", send_outcome: "unknown_route"} =
               Repo.one!(from(delivery in ActorInputDelivery))

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "route retry reuses the materialized user message and started llm turn" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      dead_route = unique_route()
      live_route = unique_route()

      assert {:ok, _worker} = admit_worker(dead_route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route", llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert Repo.one!(
               from(message in Message, where: message.role == "user", select: count(message.id))
             ) == 1

      assert Repo.get!(LlmTurn, first_turn.id).status == "started"

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, _worker} = admit_worker(live_route)

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 2, :second))

      assert second_turn.id == first_turn.id

      assert Repo.one!(
               from(message in Message, where: message.role == "user", select: count(message.id))
             ) == 1

      assert_receive {:actor_lane, envelope}
      assert envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == first_turn.id

      deliveries =
        Repo.all(from(delivery in ActorInputDelivery, order_by: [asc: delivery.attempt_no]))

      assert Enum.map(deliveries, & &1.state) == ["sent"]
      assert Enum.map(deliveries, & &1.attempt_no) == [2]
    end

    test "expired activation lease is failed before retrying a ready input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      dead_route = unique_route()
      live_route = unique_route()

      assert {:ok, _worker} = admit_worker(dead_route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route", llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 1
               )

      assert Repo.get!(ActorInput, input.id).input_state == "open"
      assert Repo.get!(LlmTurn, first_turn.id).status == "started"

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, _worker} = admit_worker(live_route)

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 3, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"

      activations =
        ActorSessionActivation
        |> order_by([activation], asc: activation.actor_epoch)
        |> Repo.all()

      assert Enum.map(activations, & &1.status) == ["failed", "active"]
      assert Enum.map(activations, & &1.actor_epoch) == [1, 2]

      assert_receive {:actor_lane, envelope}
      assert envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == second_turn.id

      assert ["sent"] =
               ActorInputDelivery
               |> where([delivery], delivery.actor_input_id == ^input.id)
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

    test "turn_error fails the current turn and keeps the input open for a new activation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_lane, first_envelope}
      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      assert {:ok, %{status: :turn_failed}} =
               ActorRuntime.handle_turn_error(%{
                 "turn_error" => %{
                   "turn" => first_turn_ref,
                   "code" => "worker_loop_failed",
                   "message" => "worker loop failed",
                   "details_json" => %{"retryable" => true}
                 }
               })

      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert Repo.one!(from(delivery in ActorInputDelivery, select: delivery.state)) ==
               "superseded"

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0

      assert {:ok, %{llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 2, :second))

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"

      assert Repo.one!(
               from(message in Message, where: message.role == "user", select: count(message.id))
             ) == 1

      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["actor_epoch"] == 2
    end

    test "expired activation rejects late final proposal without provider output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      Repo.update_all(
        from(activation in ActorSessionActivation,
          where: activation.activation_uid == ^turn_ref["activation_uid"]
        ),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)]
      )

      assert {:error, :activation_lease_expired} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert Repo.get!(LlmTurn, llm_turn.id).status == "started"
      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "worker progress extends the matching in-flight activation lease" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: _input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: _llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 2
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
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
end
