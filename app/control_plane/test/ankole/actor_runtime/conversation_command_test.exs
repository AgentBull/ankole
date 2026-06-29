defmodule Ankole.ActorRuntime.ConversationCommandTest do
  use Ankole.ActorRuntimeCase

  describe "conversation and summary commands" do
    test "/compress is parsed as command.compress for the worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert input.type == "command.compress"
      assert input.payload["type"] == "command.compress"
      assert get_in(input.payload, ["data", "entry", "text"]) == "/compress"
      assert get_in(input.payload, ["data", "command", "name"]) == "compress"
      assert get_in(input.payload, ["data", "command", "raw"]) == "/compress"
      assert Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
      assert Repo.aggregate(Message, :count) == 0
    end

    test "new command with args rolls over the window and starts a generation from the args" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: _first_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "old task", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, first_envelope}
      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      first_input_ids =
        Enum.map(first_envelope["body"]["turn_start"]["inputs"], & &1["actor_input_id"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => first_turn_ref,
                   "accepted_actor_input_ids" => first_input_ids
                 }
               })

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => first_turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "old answer"}
                 }
               })

      assert {:ok, %{actor_input: new_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new fresh task\nwith context", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: next_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert next_turn.conversation_id != first_turn.conversation_id
      assert Repo.get!(Conversation, first_turn.conversation_id).ended_at

      assert %Message{role: "user", content: [%{"text" => "fresh task\nwith context"}]} =
               Repo.one!(
                 from(message in Message,
                   where: message.metadata["actor_input_id"] == ^new_input.id,
                   where: message.role == "user"
                 )
               )

      assert_receive {:actor_lane, next_envelope}
      assert [%{"payload_json" => payload}] = next_envelope["body"]["turn_start"]["inputs"]
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh task\nwith context"
    end

    test "new command with args stops an active generation before starting the next window" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: old_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "old active task", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: old_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, old_envelope}
      old_start = old_envelope["body"]["turn_start"]
      old_turn_ref = old_start["turn"]
      old_input_ids = Enum.map(old_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => old_turn_ref,
                   "accepted_actor_input_ids" => old_input_ids
                 }
               })

      assert {:ok, %{actor_input: new_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new fresh active task", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: new_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, stop_control}
      assert stop_control["body"]["type"] == "turn_control"
      assert stop_control["body"]["turn_control"]["command"] == "stop"

      assert stop_control["body"]["turn_control"]["turn"]["llm_turn_id"] ==
               old_turn_ref["llm_turn_id"]

      assert stop_control["body"]["turn_control"]["payload_json"]["reason"] == "command.new"

      assert_receive {:actor_lane, new_envelope}
      new_start = new_envelope["body"]["turn_start"]

      assert [%{"actor_input_id" => new_input_id, "payload_json" => payload}] =
               new_start["inputs"]

      assert new_input_id == new_input.id
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh active task"

      assert new_turn.conversation_id != old_turn.conversation_id
      assert Repo.get!(Conversation, old_turn.conversation_id).ended_at
      assert Repo.get!(LlmTurn, old_turn.id).status == "cancelled"
      refute Repo.get(ActorInput, old_input.id)
      assert Repo.get!(ActorInput, new_input.id).input_state == "open"
    end

    test "new command with args waits for a worker and is retried as an open input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, old_conversation} =
               Ankole.AIAgent.ensure_conversation(agent.uid, "signal-channel:lark:chat:group-a")

      assert {:ok, %{actor_input: new_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new fresh task after worker returns", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :waiting_for_worker,
                command: "command.new",
                stop_control_outcomes: []
              }} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorInput, new_input.id).input_state == "open"
      assert Repo.get!(Conversation, old_conversation.id).ended_at
      assert Repo.aggregate(LlmTurn, :count) == 0
      assert Repo.aggregate(ActorInputDelivery, :count) == 0

      refute Repo.exists?(
               from(message in Message,
                 where: message.metadata["actor_input_id"] == ^new_input.id,
                 where: message.role == "user"
               )
             )

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: next_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 2, :second))

      assert next_turn.conversation_id != old_conversation.id

      assert %Message{role: "user", content: [%{"text" => "fresh task after worker returns"}]} =
               Repo.one!(
                 from(message in Message,
                   where: message.metadata["actor_input_id"] == ^new_input.id,
                   where: message.role == "user"
                 )
               )

      assert_receive {:actor_lane, next_envelope}
      assert [%{"payload_json" => payload}] = next_envelope["body"]["turn_start"]["inputs"]
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh task after worker returns"
    end

    test "/compress starts a queued worker turn and summary commit RPC writes feedback" do
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

      assert {:ok, %{llm_turn: generation_turn}} =
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

      assert {:ok, %{actor_input: compress_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: compression_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert %LlmTurn{
               kind: "generation",
               status: "started",
               profile: "primary",
               input_message_ids: [compress_message_id],
               request_context: request_context
             } = Repo.get!(LlmTurn, compression_turn.id)

      refute Map.has_key?(request_context, "compression")

      assert Repo.get!(Message, compress_message_id).content == [
               %{"type" => "text", "text" => "/compress"}
             ]

      assert_receive {:actor_lane, compression_envelope}
      compression_start = compression_envelope["body"]["turn_start"]
      compression_ref = compression_start["turn"]
      compression_input_ids = Enum.map(compression_start["inputs"], & &1["actor_input_id"])

      assert compression_ref["llm_turn_id"] == compression_turn.id
      assert compression_start["model_ref"]["profile"] == "primary"

      assert [%{"type" => "command.compress", "payload_json" => compression_payload}] =
               compression_start["inputs"]

      assert get_in(compression_payload, ["data", "entry", "text"]) == "/compress"
      assert get_in(compression_payload, ["data", "command", "name"]) == "compress"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => compression_ref,
                   "accepted_actor_input_ids" => compression_input_ids
                 }
               })

      covered_message_ids =
        Message
        |> where([message], message.conversation_id == ^compression_turn.conversation_id)
        |> where([message], message.kind == "normal")
        |> where([message], message.id != ^compress_message_id)
        |> order_by([message], asc: message.inserted_at, asc: message.id)
        |> select([message], message.id)
        |> Repo.all()

      assert {:ok, malformed_envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "conversation-summary-malformed",
                   "method" => "conversation.summary.commit",
                   "payload_json" => %{
                     "turn" => compression_ref
                   }
                 },
                 route
               )

      assert get_in(malformed_envelope, ["body", "type"]) == "rpc_error"
      assert get_in(malformed_envelope, ["body", "rpc_error", "code"]) == "summary_missing"

      assert {:ok, invalid_cover_envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "conversation-summary-bad-cover",
                   "method" => "conversation.summary.commit",
                   "payload_json" => %{
                     "turn" => compression_ref,
                     "summary" => %{
                       "text" => "This should not commit.",
                       "covered_message_ids" => [Ecto.UUID.generate()]
                     }
                   }
                 },
                 route
               )

      assert get_in(invalid_cover_envelope, ["body", "type"]) == "rpc_error"

      assert get_in(invalid_cover_envelope, ["body", "rpc_error", "code"]) ==
               "summary_covered_message_not_found"

      assert Repo.get!(LlmTurn, compression_turn.id).status == "started"

      refute Repo.exists?(
               from(consumption in ActorInputConsumption,
                 where: consumption.actor_input_id == ^compress_input.id
               )
             )

      refute Repo.exists?(
               from(message in Message,
                 where: message.conversation_id == ^compression_turn.conversation_id,
                 where: message.kind == "summary"
               )
             )

      assert {:ok, %{actor_input: steer_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer keep the deployment details", explicit: true}),
                 now: DateTime.add(@base_time, 4, :second)
               )

      assert {:ok,
              %{
                status: :active_steer_nudged,
                send_outcome: "sent_or_queued",
                turn_ref: steered_compression_ref,
                delivery: steer_delivery
              }} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 5, :second))

      assert steered_compression_ref["llm_turn_id"] == compression_ref["llm_turn_id"]
      assert steered_compression_ref["revision"] == compression_ref["revision"] + 1
      assert Repo.get!(ActorInputDelivery, steer_delivery.id).state == "sent"

      assert_receive {:actor_lane, mailbox_envelope}
      assert mailbox_envelope["body"]["type"] == "mailbox_updated"
      mailbox_update = mailbox_envelope["body"]["mailbox_updated"]
      assert mailbox_update["turn"] == steered_compression_ref

      assert [%{"actor_input_id" => steer_input_id, "payload_json" => steer_payload}] =
               mailbox_update["inputs"]

      assert steer_input_id == steer_input.id

      assert get_in(steer_payload, ["data", "command", "argsText"]) ==
               "keep the deployment details"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => steered_compression_ref,
                   "accepted_actor_input_ids" => [steer_input.id]
                 }
               })

      assert Repo.get!(ActorInputDelivery, steer_delivery.id).state == "accepted"

      assert {:ok, summary_envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "conversation-summary-commit-1",
                   "method" => "conversation.summary.commit",
                   "payload_json" => %{
                     "turn" => steered_compression_ref,
                     "summary" => %{
                       "text" => "Compressed summary for PING and PONG.",
                       "covered_message_ids" => covered_message_ids
                     },
                     "usage_json" => %{"input_tokens" => 10},
                     "provider_metadata_json" => %{
                       "profile" => "light",
                       "model" => "openai/gpt-5.4-nano",
                       "runtime_provider" => "openrouter"
                     }
                   }
                 },
                 route
               )

      summary_payload = get_in(summary_envelope, ["body", "rpc_response", "payload_json"])
      assert summary_payload["status"] == "committed"

      assert %Message{kind: "summary", content: [%{"text" => summary_text}]} =
               Repo.get!(Message, summary_payload["summary_message_id"])

      assert summary_text == "Compressed summary for PING and PONG."
      assert summary_payload["covered_message_ids"] == covered_message_ids

      assert Repo.get!(Message, summary_payload["summary_message_id"]).covers_range["message_ids"] ==
               covered_message_ids

      assert Repo.get!(LlmTurn, compression_turn.id).status == "succeeded"
      assert Repo.get!(LlmTurn, compression_turn.id).provider_metadata["profile"] == "light"
      assert Repo.get!(LlmTurn, generation_turn.id).status == "succeeded"

      assert %ActorInputConsumption{
               type: "command.compress",
               llm_turn_id: compression_turn_id
             } =
               Repo.one!(
                 from(consumption in ActorInputConsumption,
                   where: consumption.actor_input_id == ^compress_input.id
                 )
               )

      assert compression_turn_id == compression_turn.id

      assert %OutboxEntry{payload: %{"text" => "Conversation compressed."}} =
               Repo.one!(
                 from(outbox in OutboxEntry,
                   where: outbox.source_actor_input_id == ^compress_input.id
                 )
               )

      assert %ActorInput{input_state: "open"} = Repo.get!(ActorInput, steer_input.id)

      refute Repo.exists?(
               from(consumption in ActorInputConsumption,
                 where: consumption.actor_input_id == ^steer_input.id
               )
             )

      refute Repo.exists?(
               from(delivery in ActorInputDelivery,
                 where: delivery.actor_input_id == ^steer_input.id
               )
             )

      assert {:ok, duplicate_envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "conversation-summary-commit-duplicate",
                   "method" => "conversation.summary.commit",
                   "payload_json" => %{
                     "turn" => steered_compression_ref,
                     "summary" => %{
                       "text" => "Compressed summary for PING and PONG.",
                       "covered_message_ids" => covered_message_ids
                     }
                   }
                 },
                 route
               )

      duplicate_payload = get_in(duplicate_envelope, ["body", "rpc_response", "payload_json"])
      assert duplicate_payload["status"] == "already_committed"
      assert duplicate_payload["llm_turn_id"] == compression_turn.id
      refute Map.has_key?(duplicate_payload, "summary_message_id")

      assert Repo.aggregate(
               from(message in Message,
                 where: message.conversation_id == ^compression_turn.conversation_id,
                 where: message.kind == "summary"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(outbox in OutboxEntry,
                 where: outbox.source_actor_input_id == ^compress_input.id
               ),
               :count
             ) == 1

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: steer_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 6, :second))

      assert_receive {:actor_lane, steer_envelope}
      steer_start = steer_envelope["body"]["turn_start"]
      assert Enum.map(steer_start["inputs"], & &1["actor_input_id"]) == [steer_input.id]

      assert [%{"type" => "command.steer", "payload_json" => deferred_steer_payload}] =
               steer_start["inputs"]

      assert get_in(deferred_steer_payload, ["data", "command", "argsText"]) ==
               "keep the deployment details"

      assert steer_turn.conversation_id == compression_turn.conversation_id
    end
  end
end
