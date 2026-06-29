defmodule Ankole.ActorRuntime.EntryLifecycleTest do
  use Ankole.ActorRuntimeCase

  describe "entry lifecycle input recovery" do
    test "removed input rejects late final proposal without provider output" do
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

      assert {:ok, %{canceled_actor_inputs: 1, lifecycle_inputs: []}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   ingress_event_id: "recall-before-final",
                   signal_channel_id: input.signal_channel_id,
                   provider_entry_id: input.provider_entry_id,
                   provider_thread_id: input.provider_thread_id
                 }),
                 provider_lifecycle_kind: :recalled,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert_receive {:actor_lane, retry_control}
      assert retry_control["body"]["type"] == "turn_control"
      assert retry_control["body"]["turn_control"]["command"] == "retry"

      assert {:error, :llm_turn_not_started} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert Repo.get!(LlmTurn, llm_turn.id).status == "cancelled"
      refute Repo.get(ActorInput, input.id)

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "removing one entry from an in-flight merged batch retries the remaining batch" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      alice = %{principal_uid: "alice", id: "provider-alice", display_name: "Alice"}

      assert {:ok, %{inbound_batch: batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: true,
                   ingress_event_id: "evt-batch-first",
                   provider_entry_id: "msg-batch-first",
                   author: alice,
                   text: "first"
                 }),
                 now: @base_time
               )

      assert {:ok, %{inbound_batch: updated_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   explicit: false,
                   ingress_event_id: "evt-batch-second",
                   provider_entry_id: "msg-batch-second",
                   author: alice,
                   text: "second"
                 }),
                 now: DateTime.add(@base_time, 100, :millisecond)
               )

      assert updated_batch.id == batch.id

      assert {:ok, [%{actor_input: input}]} =
               SignalsGateway.finalize_due_inbound_batches(
                 now: DateTime.add(@base_time, 700, :millisecond)
               )

      original_ingress_event_id = input.ingress_event_id
      assert get_in(input.payload, ["data", "entry", "text"]) == "first\nsecond"

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

      assert {:ok, %{retried_actor_inputs: 1, canceled_actor_inputs: 0, lifecycle_inputs: []}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   ingress_event_id: "recall-batch-first",
                   signal_channel_id: input.signal_channel_id,
                   provider_entry_id: "msg-batch-first",
                   provider_thread_id: input.provider_thread_id
                 }),
                 provider_lifecycle_kind: :recalled,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert_receive {:actor_lane, retry_control}
      assert retry_control["body"]["type"] == "turn_control"
      assert retry_control["body"]["turn_control"]["command"] == "retry"
      assert retry_control["body"]["turn_control"]["payload_json"]["reason"] == "removed"

      assert Repo.get!(LlmTurn, llm_turn.id).status == "cancelled"

      assert %Message{status: "retracted"} =
               Repo.one!(
                 from(message in Message,
                   where: message.event_id == ^original_ingress_event_id
                 )
               )

      assert %ActorInput{} = updated_input = Repo.get!(ActorInput, input.id)
      assert updated_input.provider_entry_id == "msg-batch-second"
      assert updated_input.ingress_event_id == "retry:#{input.id}:without:msg-batch-first"
      assert get_in(updated_input.payload, ["data", "entry", "text"]) == "second"

      assert [%{"provider_entry_id" => "msg-batch-second"}] =
               get_in(updated_input.payload, ["data", "entries"])

      assert get_in(updated_input.payload, ["data", "entry", "retry_of_llm_turn_id"]) ==
               llm_turn.id

      assert {:error, :llm_turn_not_started} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "TOO LATE"}
                 }
               })

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: retry_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert retry_turn.kind == "retry_generation"
      assert_receive {:actor_lane, retry_envelope}
      assert [retry_turn_input] = retry_envelope["body"]["turn_start"]["inputs"]
      assert retry_turn_input["actor_input_id"] == input.id
      assert retry_turn_input["payload_json"]["data"]["entry"]["text"] == "second"
    end

    test "historical removal records a lifecycle note without rewriting history or starting a turn" do
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
                 group_entry(%{text: "old fact", explicit: true}),
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
                   "reply" => %{"text" => "old answer"}
                 }
               })

      assert {:ok, %{canceled_actor_inputs: 0, lifecycle_inputs: [lifecycle_input]}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   ingress_event_id: "recall-historical",
                   signal_channel_id: input.signal_channel_id,
                   provider_entry_id: input.provider_entry_id,
                   provider_thread_id: input.provider_thread_id
                 }),
                 provider_lifecycle_kind: :recalled,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :entry_lifecycle_recorded, lifecycle_input: processed_input}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert processed_input.id == lifecycle_input.id
      refute_receive {:actor_lane, _envelope}, 100
      refute Repo.get(ActorInput, lifecycle_input.id)

      assert Repo.aggregate(LlmTurn, :count) == 1
      assert Repo.get!(LlmTurn, first_turn.id).status == "succeeded"
      assert Repo.aggregate(OutboxEntry, :count) == 1
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.aggregate(ActorInputConsumption, :count) == 2

      assert Repo.one!(
               from(message in Message,
                 where: message.role == "user" and message.kind == "normal",
                 select: message.content
               )
             ) == [%{"type" => "text", "text" => "old fact"}]

      assert Repo.one!(
               from(message in Message,
                 where: message.role == "assistant" and message.kind == "normal",
                 select: message.content
               )
             ) == [%{"type" => "text", "text" => "old answer"}]

      lifecycle_note =
        Repo.one!(
          from(message in Message,
            where: message.event_id == "recall-historical"
          )
        )

      assert %Message{role: "user", kind: "introspection", content: [%{"text" => note}]} =
               lifecycle_note

      assert note =~ "previously visible user entry was removed"
      assert note =~ input.provider_entry_id
      assert lifecycle_note.metadata["provider_entry_id"] == input.provider_entry_id
      assert lifecycle_note.metadata["lifecycle"]["kind"] == "removed"
      assert lifecycle_note.metadata["lifecycle"]["provider_kind"] == "recalled"
    end

    test "removing an entry from an ended conversation does not annotate the new conversation" do
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
                 group_entry(%{text: "old task", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: old_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, old_envelope}
      old_start = old_envelope["body"]["turn_start"]
      old_ref = old_start["turn"]
      old_input_ids = Enum.map(old_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => old_ref,
                   "accepted_actor_input_ids" => old_input_ids
                 }
               })

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => old_ref,
                   "messages" => [],
                   "reply" => %{"text" => "old answer"}
                 }
               })

      assert {:ok, %{actor_input: new_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new fresh task", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: new_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, new_envelope}
      new_start = new_envelope["body"]["turn_start"]
      new_ref = new_start["turn"]
      new_input_ids = Enum.map(new_start["inputs"], & &1["actor_input_id"])

      assert new_input.id in new_input_ids
      assert new_turn.conversation_id != old_turn.conversation_id
      assert Repo.get!(Conversation, old_turn.conversation_id).ended_at

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => new_ref,
                   "accepted_actor_input_ids" => new_input_ids
                 }
               })

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => new_ref,
                   "messages" => [],
                   "reply" => %{"text" => "new answer"}
                 }
               })

      message_count_before_recall = Repo.aggregate(Message, :count)
      turn_count_before_recall = Repo.aggregate(LlmTurn, :count)
      outbox_count_before_recall = Repo.aggregate(OutboxEntry, :count)

      assert {:ok, %{canceled_actor_inputs: 0, lifecycle_inputs: [lifecycle_input]}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   ingress_event_id: "recall-old-after-new",
                   signal_channel_id: old_input.signal_channel_id,
                   provider_entry_id: old_input.provider_entry_id,
                   provider_thread_id: old_input.provider_thread_id
                 }),
                 provider_lifecycle_kind: :recalled,
                 now: DateTime.add(@base_time, 4, :second)
               )

      assert {:ok,
              %{
                status: :entry_lifecycle_ignored,
                lifecycle_input: processed_input,
                consumption: lifecycle_consumption
              }} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 5, :second))

      assert processed_input.id == lifecycle_input.id
      assert lifecycle_consumption.conversation_id == old_turn.conversation_id
      refute Repo.get(ActorInput, lifecycle_input.id)
      refute_receive {:actor_lane, _envelope}, 100

      assert Repo.aggregate(Message, :count) == message_count_before_recall
      assert Repo.aggregate(LlmTurn, :count) == turn_count_before_recall
      assert Repo.aggregate(OutboxEntry, :count) == outbox_count_before_recall

      refute Repo.get_by(Message,
               conversation_id: new_turn.conversation_id,
               event_id: "recall-old-after-new"
             )
    end
  end
end
