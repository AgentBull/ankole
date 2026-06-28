defmodule Ankole.ActorRuntime.CoreCommitTest do
  use Ankole.ActorRuntimeCase

  describe "core turn commits" do
    test "supervised runtime owners automatically dispatch PING to a worker and send PONG outbox" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      test_pid = self()
      route = unique_route()

      start_supervised!({ActivationManager, interval_ms: 20, limit: 10})

      start_supervised!(
        {OutboxDispatcher,
         interval_ms: 20,
         adapter_resolver: fn _outbox ->
           %{
             capabilities: [:reply_entry],
             send: fn outbox ->
               send(test_pid, {:auto_pong_outbox_sent, outbox.payload})
               {:ok, %{provider_entry_id: "provider-auto-pong"}}
             end
           }
         end}
      )

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

      assert_receive {:actor_lane, envelope}, 2_000

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert turn_ref["actor"]["agent_uid"] == agent.uid
      assert is_binary(turn_ref["actor"]["session_id"])
      refute Map.has_key?(turn_ref["actor"], "display_name")
      refute Map.has_key?(turn_ref["actor"], "role")

      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      assert {:ok, _deliveries} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, _result} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert_receive {:auto_pong_outbox_sent, %{"text" => "PONG"}}, 2_000

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputConsumption, :count) == 1
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.one!(from(turn in LlmTurn, select: turn.status)) == "succeeded"

      assert Repo.one!(
               from(message in Message,
                 where: message.role == "assistant",
                 select: message.content
               )
             ) == [
               %{"type" => "text", "text" => "PONG"}
             ]

      assert Repo.one!(from(outbox in OutboxEntry, select: outbox.status)) == :succeeded
    end

    test "commits accepted PING input as assistant PONG and provider outbox" do
      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")

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

      assert %Message{metadata: user_metadata} =
               Repo.one!(
                 from(message in Message,
                   where: message.role == "user",
                   where: message.event_id == ^input.ingress_event_id
                 )
               )

      refute get_in(user_metadata, ["message_context", "time"])

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert input_ids == [input.id]

      assert turn_start["request_context"]["actor_key"] == %{
               "agent_uid" => agent.uid,
               "session_id" => input.session_id
             }

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :committed, assistant_message: assistant_message}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputConsumption, :count) == 1
      assert Repo.aggregate(ActorInputDelivery, :count) == 0

      assert Repo.get!(LlmTurn, llm_turn.id).status == "succeeded"

      assert %Message{content: [%{"text" => "PONG"}]} =
               Repo.get!(Message, assistant_message.id)

      outbox = Repo.one!(from(outbox in OutboxEntry))
      assert outbox.source_actor_input_id == input.id
      assert outbox.llm_turn_id == llm_turn.id
      assert outbox.assistant_message_id == assistant_message.id
      assert outbox.operation == :reply
      assert outbox.payload == %{"text" => "PONG"}
      assert outbox.status == :created

      assert {:ok, sent_outbox} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 outbox.outbound_key,
                 %{
                   capabilities: [:reply_entry],
                   send: fn outbox ->
                     send(self(), {:pong_outbox_sent, outbox.payload})
                     {:ok, %{provider_entry_id: "provider-pong-1"}}
                   end
                 }
               )

      assert_receive {:pong_outbox_sent, %{"text" => "PONG"}}
      assert sent_outbox.status == :succeeded
      assert sent_outbox.provider_entry_id == "provider-pong-1"
    end

    test "commits a provider outbox for each consecutive IM turn in one channel" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: first_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id:
                     "evt-first-" <> Integer.to_string(System.unique_integer([:positive])),
                   signal_channel_id: "lark:chat:two-turns",
                   provider_entry_id: "msg-first",
                   provider_thread_id: "thread-two-turns",
                   text: "first request",
                   explicit: true
                 }),
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

      assert first_input_ids == [first_input.id]

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
                   "reply" => %{"text" => "FIRST"}
                 }
               })

      assert %OutboxEntry{payload: %{"text" => "FIRST"}} =
               Repo.get_by!(OutboxEntry,
                 source_actor_input_id: first_input.id,
                 llm_turn_id: first_turn.id
               )

      assert {:ok, %{actor_input: second_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id:
                     "evt-second-" <>
                       Integer.to_string(System.unique_integer([:positive])),
                   signal_channel_id: "lark:chat:two-turns",
                   provider_entry_id: "msg-second",
                   provider_thread_id: "thread-two-turns",
                   text: "second request",
                   explicit: true,
                   provider_time: DateTime.add(@base_time, 2, :second)
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 3, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, second_envelope}
      second_turn_ref = second_envelope["body"]["turn_start"]["turn"]

      second_input_ids =
        Enum.map(second_envelope["body"]["turn_start"]["inputs"], & &1["actor_input_id"])

      assert second_input_ids == [second_input.id]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => second_turn_ref,
                   "accepted_actor_input_ids" => second_input_ids
                 }
               })

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => second_turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "SECOND"}
                 }
               })

      assert %OutboxEntry{payload: %{"text" => "SECOND"}} =
               Repo.get_by!(OutboxEntry,
                 source_actor_input_id: second_input.id,
                 llm_turn_id: second_turn.id
               )

      assert Repo.aggregate(ActorInputConsumption, :count) == 2
      assert Repo.aggregate(OutboxEntry, :count) == 2
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
    end

    test "commits one provider outbox for the latest input in one batched IM turn" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{inbound_batch: first_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-batch-first",
                   signal_channel_id: "lark:chat:batched-turn",
                   provider_entry_id: "msg-batch-first",
                   provider_thread_id: "thread-batched-turn",
                   text: "first part",
                   explicit: true,
                   provider_time: @base_time
                 }),
                 now: @base_time
               )

      second_time = DateTime.add(@base_time, 100, :millisecond)

      assert {:ok, %{inbound_batch: second_batch}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-batch-second",
                   signal_channel_id: "lark:chat:batched-turn",
                   provider_entry_id: "msg-batch-second",
                   provider_thread_id: "thread-batched-turn",
                   text: "second part",
                   explicit: true,
                   provider_time: second_time
                 }),
                 now: second_time
               )

      assert first_batch.id == second_batch.id

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert [actor_input_id] = input_ids

      assert [%{"payload_json" => payload}] = turn_start["inputs"]
      assert get_in(payload, ["data", "entry", "text"]) == "first part\nsecond part"

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
                   "reply" => %{"text" => "ONE REPLY"}
                 }
               })

      assert %OutboxEntry{
               source_actor_input_id: source_actor_input_id,
               source_provider_entry_id: "msg-batch-second",
               target_provider_entry_id: "msg-batch-second",
               llm_turn_id: llm_turn_id,
               payload: %{"text" => "ONE REPLY"}
             } = Repo.one!(from(outbox in OutboxEntry))

      assert source_actor_input_id == actor_input_id
      assert llm_turn_id == llm_turn.id
      assert Repo.aggregate(ActorInputConsumption, :count) == 1
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
    end

    test "commits final proposal reply attachments into transcript outbox and mirror" do
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
                 group_entry(%{text: "Send the report", explicit: true}),
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

      assert input_ids == [input.id]

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :committed, assistant_message: assistant_message}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{
                     "text" => "Here is the report.",
                     "attachments" => [
                       %{
                         "agent_computer_path" => "/workspace/user-files/reports/a.txt",
                         "name" => "report.txt",
                         "mime_type" => "text/plain",
                         "size" => 16
                       }
                     ]
                   }
                 }
               })

      assert %Message{content: [text_part, attachment_part]} =
               Repo.get!(Message, assistant_message.id)

      assert text_part == %{"type" => "text", "text" => "Here is the report."}

      assert attachment_part == %{
               "type" => "attachment",
               "agent_computer_path" => "/workspace/user-files/reports/a.txt",
               "user_files_relative_path" => "reports/a.txt",
               "name" => "report.txt",
               "mime_type" => "text/plain",
               "size" => 16
             }

      outbox = Repo.one!(from(outbox in OutboxEntry))

      assert outbox.llm_turn_id == llm_turn.id

      assert outbox.payload == %{
               "text" => "Here is the report.",
               "attachments" => [
                 %{
                   "agent_computer_path" => "/workspace/user-files/reports/a.txt",
                   "user_files_relative_path" => "reports/a.txt",
                   "name" => "report.txt",
                   "mime_type" => "text/plain",
                   "size" => 16
                 }
               ]
             }

      assert {:ok, _sent_outbox} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 outbox.outbound_key,
                 %{
                   capabilities: [:reply_entry],
                   send: fn outbox ->
                     send(self(), {:attachment_outbox_sent, outbox.payload})
                     {:ok, %{provider_entry_id: "provider-report-1"}}
                   end
                 }
               )

      assert_receive {:attachment_outbox_sent,
                      %{
                        "attachments" => [
                          %{"agent_computer_path" => "/workspace/user-files/reports/a.txt"}
                        ]
                      }}

      mirrored =
        Repo.one!(
          from entry in SignalEntry,
            where: entry.provider_entry_id == "provider-report-1"
        )

      assert mirrored.attachments == [
               %{
                 "agent_computer_path" => "/workspace/user-files/reports/a.txt",
                 "user_files_relative_path" => "reports/a.txt",
                 "name" => "report.txt",
                 "mime_type" => "text/plain",
                 "size" => 16
               }
             ]
    end
  end
end
