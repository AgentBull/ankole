defmodule Ankole.ActorRuntime.SteerStopCommandTest do
  use Ankole.ActorRuntimeCase

  describe "steer, compress, and stop commands" do
    test "inactive steer command starts a generation with the steer args" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: steer_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer focus on risk", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(LlmTurn, turn.id).kind == "generation"

      assert %Message{content: [%{"text" => "focus on risk"}]} =
               Repo.one!(
                 from(message in Message,
                   where: message.metadata["actor_input_id"] == ^steer_input.id
                 )
               )

      assert_receive {:actor_lane, envelope}
      assert [%{"payload_json" => payload}] = envelope["body"]["turn_start"]["inputs"]
      assert get_in(payload, ["data", "command", "argsText"]) == "focus on risk"
    end

    test "active steer is delivered to the active generation and fences stale final proposal" do
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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])
      assert input_ids == [input.id]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{actor_input: steer_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer change course", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok,
              %{
                status: :active_steer_nudged,
                send_outcome: "sent_or_queued",
                turn_ref: steered_turn_ref,
                delivery: steer_delivery
              }} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert Repo.get!(ActorInput, steer_input.id).input_state == "open"
      assert Repo.get!(ActorInputDelivery, steer_delivery.id).state == "sent"
      assert steered_turn_ref["llm_turn_id"] == turn_ref["llm_turn_id"]
      assert steered_turn_ref["revision"] == turn_ref["revision"] + 1

      assert_receive {:actor_lane, mailbox_envelope}
      assert mailbox_envelope["durability"] == "CONTROL_EPHEMERAL"
      assert mailbox_envelope["body"]["type"] == "mailbox_updated"
      mailbox_update = mailbox_envelope["body"]["mailbox_updated"]
      assert mailbox_update["reason"] == "command.steer"
      assert mailbox_update["turn"] == steered_turn_ref
      steer_input_id = steer_input.id

      assert [%{"actor_input_id" => ^steer_input_id, "payload_json" => steer_payload}] =
               mailbox_update["inputs"]

      assert get_in(steer_payload, ["data", "command", "argsText"]) == "change course"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => steered_turn_ref,
                   "accepted_actor_input_ids" => [steer_input.id]
                 }
               })

      assert Repo.get!(ActorInputDelivery, steer_delivery.id).state == "accepted"

      assert {:error, :stale_revision} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => steered_turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      refute Repo.get(ActorInput, input.id)
      refute Repo.get(ActorInput, steer_input.id)
      assert Repo.aggregate(ActorInputConsumption, :count) == 2
      assert Repo.aggregate(ActorInputDelivery, :count) == 0

      assert %OutboxEntry{
               source_actor_input_id: source_actor_input_id,
               source_provider_entry_id: source_provider_entry_id,
               payload: %{"text" => "PONG"}
             } = Repo.one!(from(outbox in OutboxEntry))

      assert source_actor_input_id == input.id
      assert source_provider_entry_id == input.provider_entry_id

      assert Repo.one!(
               from(message in Message,
                 where: message.kind == "introspection",
                 select: message.event_source
               )
             ) == "ai_agent.command.steer"

      assert Repo.aggregate(LlmTurn, :count) == 1
    end

    test "active compress command waits for the current generation to finish" do
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

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: active_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])
      assert input_ids == [input.id]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{actor_input: compress_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress release notes", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert compress_input.type == "command.compress"

      assert {:ok, %{status: :idle}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      refute_receive {:actor_lane, _envelope}, 50
      assert Repo.get!(ActorInput, compress_input.id).input_state == "open"

      refute Repo.exists?(
               from(delivery in ActorInputDelivery,
                 where: delivery.actor_input_id == ^compress_input.id
               )
             )

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      refute Repo.get(ActorInput, input.id)
      assert Repo.get!(LlmTurn, active_turn.id).status == "succeeded"

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: compression_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 4, :second))

      assert_receive {:actor_lane, compression_envelope}
      compression_start = compression_envelope["body"]["turn_start"]

      assert [%{"type" => "command.compress", "actor_input_id" => actor_input_id}] =
               compression_start["inputs"]

      assert actor_input_id == compress_input.id
      assert compression_start["turn"]["llm_turn_id"] == compression_turn.id
    end

    test "stop command cancels active generation and rejects late final proposal" do
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

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert input_ids == [input.id]

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{actor_input: stop_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/stop", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert stop_input.type == "command.stop"

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Stopped.",
                stop_control_outcomes: [%{send_outcome: "sent_or_queued"}]
              }} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, stop_control}
      assert stop_control["body"]["type"] == "turn_control"
      assert stop_control["body"]["turn_control"]["command"] == "stop"

      assert stop_control["body"]["turn_control"]["turn"]["llm_turn_id"] ==
               turn_ref["llm_turn_id"]

      assert stop_control["body"]["turn_control"]["payload_json"]["reason"] == "command.stop"

      refute Repo.get(ActorInput, input.id)
      refute Repo.get(ActorInput, stop_input.id)

      assert %LlmTurn{
               status: "cancelled",
               response: %{"cancel_code" => "command.stop"},
               completed_at: %DateTime{}
             } = Repo.get!(LlmTurn, llm_turn.id)

      assert %ActorInputDelivery{state: "superseded"} =
               Repo.one!(
                 from(delivery in ActorInputDelivery,
                   where: delivery.llm_turn_id == ^llm_turn.id
                 )
               )

      conversation = Repo.get!(Ankole.AIAgent.Schemas.Conversation, llm_turn.conversation_id)
      assert conversation.generation["cancelled_at"]

      assert {:error, :llm_turn_not_started} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "TOO LATE"}
                 }
               })

      assert %OutboxEntry{payload: %{"text" => "Stopped."}} =
               Repo.one!(
                 from(outbox in OutboxEntry,
                   where: outbox.source_actor_input_id == ^stop_input.id
                 )
               )
    end
  end
end
