defmodule Ankole.ActorRuntime.RetryCommandTest do
  use Ankole.ActorRuntimeCase

  describe "retry commands" do
    test "retry command queues a retry generation without command feedback" do
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

      assert {:ok, %{llm_turn: first_turn}} =
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

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert {:ok, %{actor_input: retry_command}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/retry", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :command_consumed, retry_actor_input: retry_input}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      refute Repo.get(ActorInput, retry_command.id)
      assert Repo.get!(ActorInput, retry_input.id).payload["data"]["entry"]["text"] == "PING"

      assert Repo.get!(ActorInput, retry_input.id).payload["data"]["entry"][
               "retry_of_llm_turn_id"
             ] == first_turn.id

      refute Repo.exists?(
               from(outbox in OutboxEntry,
                 where: outbox.source_actor_input_id == ^retry_command.id
               )
             )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: retry_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 4, :second))

      assert retry_turn.kind == "retry_generation"
      assert_receive {:actor_lane, retry_envelope}
      assert retry_envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == retry_turn.id
    end

    test "retry command during active generation cancels the current turn and retries its input" do
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

      assert {:ok, %{actor_input: retry_command}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/retry", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :command_consumed, retry_actor_inputs: [retry_input]}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert retry_input.id == input.id
      refute Repo.get(ActorInput, retry_command.id)

      assert_receive {:actor_lane, retry_control}
      assert retry_control["body"]["type"] == "turn_control"
      assert retry_control["body"]["turn_control"]["command"] == "retry"
      assert retry_control["body"]["turn_control"]["turn"]["llm_turn_id"] == first_turn.id
      assert retry_control["body"]["turn_control"]["payload_json"]["reason"] == "command.retry"

      assert %LlmTurn{status: "cancelled", response: %{"cancel_code" => "command.retry"}} =
               Repo.get!(LlmTurn, first_turn.id)

      assert %ActorInput{} = retried_input = Repo.get!(ActorInput, input.id)

      assert get_in(retried_input.payload, ["data", "entry", "retry_of_llm_turn_id"]) ==
               first_turn.id

      assert {:error, :llm_turn_not_started} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "TOO LATE"}
                 }
               })

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: retry_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 4, :second))

      assert retry_turn.kind == "retry_generation"
      assert_receive {:actor_lane, retry_envelope}
      assert [retry_turn_input] = retry_envelope["body"]["turn_start"]["inputs"]
      assert retry_turn_input["actor_input_id"] == input.id
      assert retry_turn_input["payload_json"]["data"]["entry"]["text"] == "PING"
    end

    test "retry command bypasses ordinary queued input while a generation is active" do
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

      assert {:ok, %{actor_input: ordinary_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "ordinary-before-retry",
                   provider_entry_id: "ordinary-before-retry",
                   text: "handle this after retry",
                   explicit: true
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{actor_input: retry_command}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/retry", explicit: true}),
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert ordinary_input.live_queue_sequence < retry_command.live_queue_sequence

      assert {:ok, %{status: :command_consumed, retry_actor_inputs: [retry_input]}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 4, :second))

      assert retry_input.id == input.id
      refute Repo.get(ActorInput, retry_command.id)
      assert Repo.get!(ActorInput, ordinary_input.id).input_state == "open"

      assert_receive {:actor_lane, retry_control}
      assert retry_control["body"]["type"] == "turn_control"
      assert retry_control["body"]["turn_control"]["command"] == "retry"

      assert %LlmTurn{status: "cancelled"} = Repo.get!(LlmTurn, first_turn.id)

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: retry_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 5, :second))

      assert retry_turn.kind == "retry_generation"
      assert_receive {:actor_lane, retry_envelope}
      assert [retry_turn_input] = retry_envelope["body"]["turn_start"]["inputs"]
      assert retry_turn_input["actor_input_id"] == input.id
      assert retry_turn_input["payload_json"]["data"]["entry"]["text"] == "PING"
    end

    test "retry command cancels an active turn even when no live delivery remains" do
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
                 lease_seconds: @long_lease_seconds
               )

      assert %ActorInputDelivery{state: "send_failed"} =
               Repo.one!(
                 from(delivery in ActorInputDelivery,
                   where: delivery.llm_turn_id == ^first_turn.id
                 )
               )

      assert {:ok, %{actor_input: retry_command}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/retry", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert input.live_queue_sequence < retry_command.live_queue_sequence

      assert {:ok, %{status: :command_consumed, retry_actor_inputs: [retry_input]}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert retry_input.id == input.id
      assert Repo.get!(LlmTurn, first_turn.id).status == "cancelled"
      refute Repo.get(ActorInput, retry_command.id)

      refute_receive {:actor_lane, _envelope}, 50

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, _worker} = admit_worker(live_route)

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: retry_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 4, :second))

      assert retry_turn.kind == "retry_generation"
      assert_receive {:actor_lane, retry_envelope}
      assert [retry_turn_input] = retry_envelope["body"]["turn_start"]["inputs"]
      assert retry_turn_input["actor_input_id"] == input.id
      assert retry_turn_input["payload_json"]["data"]["entry"]["text"] == "PING"
    end
  end
end
