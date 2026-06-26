defmodule Ankole.ActorRuntimeTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  alias Ankole.AIAgent.LlmProviders
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.Actors.ActorInputConsumption
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.ActivationManager
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.ActorRuntime.Reconciler
  alias Ankole.ActorRuntime.WorkerBootstrap
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @long_lease_seconds 604_800

  describe "PING/PONG actor runtime path" do
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
               SignalsGateway.emit_entry(
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
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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

    test "commits final proposal reply attachments into transcript outbox and mirror" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
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

    test "real provider final proposal must include visible reply text" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _provider} =
               LlmProviders.create_provider(%{
                 provider_id: "openrouter-commit-guard",
                 provider_source: "openrouter",
                 credential: "sk-test",
                 connection_options: %{"base_url" => "https://openrouter.ai/api/v1"}
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "primary", %{
                 provider_id: "openrouter-commit-guard",
                 model: "google/gemini-3.5-flash"
               })

      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "Call a tool and answer", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert %LlmTurn{
               provider: "openrouter",
               provider_metadata: %{"provider_id" => "openrouter-commit-guard"}
             } = Repo.get!(LlmTurn, llm_turn.id)

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:error, :proposal_reply_missing} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => []
                 }
               })

      assert Repo.get!(ActorInput, input.id).input_state == "open"
      assert Repo.get!(LlmTurn, llm_turn.id).status == "started"

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "commits final proposal telemetry for real provider turns" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _provider} =
               LlmProviders.create_provider(%{
                 provider_id: "openrouter-telemetry-commit",
                 provider_source: "openrouter",
                 credential: "sk-test",
                 connection_options: %{"base_url" => "https://openrouter.ai/api/v1"}
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "primary", %{
                 provider_id: "openrouter-telemetry-commit",
                 model: "google/gemini-3.5-flash"
               })

      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, _result} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "Use the tool and answer", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert %LlmTurn{provider_metadata: %{"provider_id" => "openrouter-telemetry-commit"}} =
               Repo.get!(LlmTurn, llm_turn.id)

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
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
                   "reply" => %{"text" => "Tool result committed"},
                   "usage_json" => %{
                     "input" => 11,
                     "output" => 7,
                     "cacheRead" => 2,
                     "cacheWrite" => 0,
                     "totalTokens" => 20,
                     "cost" => %{
                       "input" => 0.0011,
                       "output" => 0.0021,
                       "cacheRead" => 0.0,
                       "cacheWrite" => 0.0,
                       "total" => 0.0032
                     }
                   },
                   "provider_metadata_json" => %{
                     "provider_source" => "openrouter",
                     "response_id" => "resp_123",
                     "response_model" => "google/gemini-3.5-flash"
                   },
                   "stop_reason" => "stop",
                   "tool_results_json" => [
                     %{
                       "tool_call_id" => "call_1",
                       "tool_name" => "command",
                       "args" => %{"cmd" => "printf ok"},
                       "is_error" => false,
                       "result" => %{
                         "content" => [%{"type" => "text", "text" => "ok"}]
                       }
                     }
                   ]
                 }
               })

      assert %LlmTurn{} = persisted = Repo.get!(LlmTurn, llm_turn.id)
      assert persisted.status == "succeeded"
      assert persisted.usage["input"] == 11
      assert persisted.usage["totalTokens"] == 20
      assert persisted.provider_metadata["provider_id"] == "openrouter-telemetry-commit"
      assert persisted.provider_metadata["provider_source"] == "openrouter"
      assert persisted.provider_metadata["response_id"] == "resp_123"
      assert persisted.provider_metadata["response_model"] == "google/gemini-3.5-flash"
      assert persisted.response["stop_reason"] == "stop"

      assert [
               %{
                 "tool_call_id" => "call_1",
                 "tool_name" => "command",
                 "is_error" => false,
                 "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
               }
             ] = persisted.tool_results
    end

    test "ambient silence consumes merged observation without visible output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "The deploy finished.", explicit: false}),
                 now: @base_time
               )

      assert {:ok, %{status: :idle}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: recognizer_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 2, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert %LlmTurn{kind: "generation", profile: "primary", status: "started"} =
               Repo.get!(LlmTurn, recognizer_turn.id)

      assert %Message{role: "im_ambient", kind: "normal", metadata: metadata} =
               Repo.one!(
                 from(message in Message,
                   where: message.metadata["actor_input_id"] == ^input.id
                 )
               )

      assert get_in(metadata, ["message_context", "room", "label"]) == "group chat \"Ops\""

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      refute Map.has_key?(turn_start, "turn_kind")
      assert turn_start["model_ref"]["profile"] == "primary"
      assert input_ids == [input.id]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :ambient_silent}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => nil
                 }
               })

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0

      refute Repo.exists?(
               from(message in Message,
                 where: message.role == "assistant"
               )
             )
    end

    test "ambient intervention proposal writes runtime watermark and visible output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   text: "Can someone ask agent for the release summary?",
                   explicit: false
                 }),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: ambient_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 2, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, ambient_envelope}
      ambient_start = ambient_envelope["body"]["turn_start"]
      ambient_ref = ambient_start["turn"]
      ambient_input_ids = Enum.map(ambient_start["inputs"], & &1["actor_input_id"])

      assert Repo.get!(LlmTurn, ambient_turn.id).kind == "generation"
      refute Map.has_key?(ambient_start, "turn_kind")

      assert [%{"type" => "im.message.may_intervene", "payload_json" => payload}] =
               ambient_start["inputs"]

      assert [%{"speaker" => "Alice", "text" => text}] =
               get_in(payload, ["data", "observed_messages"])

      assert text =~ "release summary"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => ambient_ref,
                   "accepted_actor_input_ids" => ambient_input_ids
                 }
               })

      assert {:ok, %{status: :committed, assistant_message: assistant_message}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => ambient_ref,
                   "messages" => [
                     %{
                       "role" => "im_ambient",
                       "content_json" => [
                         %{
                           "type" => "text",
                           "text" =>
                             "<chat_segment format=\"yaml\">\nmessages:\n  - speaker: Alice\n    text: release summary\n</chat_segment>"
                         }
                       ],
                       "metadata_json" => %{
                         "kind" => "introspection",
                         "event_source" => "agent_computer.ambient",
                         "event_id" => "ambient-intervention:#{ambient_turn.id}",
                         "control" => %{
                           "type" => "ambient_intervention",
                           "reason" => "The group is implicitly asking the agent to answer."
                         },
                         "message_context" => %{
                           "speaker" => %{
                             "injected" => true,
                             "display_name" => agent.uid,
                             "role" => "agent",
                             "trigger" => "introspection"
                           }
                         }
                       }
                     }
                   ],
                   "reply" => %{
                     "text" => "Here is the release summary.",
                     "content_json" => [
                       %{"type" => "text", "text" => "Here is the release summary."}
                     ]
                   }
                 }
               })

      assert %LlmTurn{kind: "generation", status: "succeeded"} =
               Repo.get!(LlmTurn, ambient_turn.id)

      assert %Message{
               role: "im_ambient",
               kind: "introspection",
               content: content,
               metadata: metadata
             } =
               Repo.one!(
                 from(message in Message,
                   where: message.kind == "introspection",
                   where: message.role == "im_ambient"
                 )
               )

      assert [%{"text" => text}] = content
      assert text =~ "<chat_segment"
      assert text =~ "release summary"
      assert get_in(metadata, ["control", "type"]) == "ambient_intervention"
      assert get_in(metadata, ["message_context", "speaker", "trigger"]) == "introspection"

      assert Repo.get!(Message, assistant_message.id).content == [
               %{"type" => "text", "text" => "Here is the release summary."}
             ]

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(OutboxEntry, :count) == 1
    end

    test "idle compress command is consumed as command feedback without transcript message" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert input.type == "command.compress"

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Conversation already fits in the active context."
              }} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      refute Repo.get(ActorInput, input.id)

      assert %ActorInputConsumption{type: "command.compress", llm_turn_id: nil} =
               Repo.one!(ActorInputConsumption)

      assert %OutboxEntry{
               payload: %{"text" => "Conversation already fits in the active context."}
             } =
               Repo.one!(OutboxEntry)

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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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

    test "idle compress with history starts light compression turn and commits summary feedback" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: _input}} =
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: compression_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert %LlmTurn{
               kind: "compression",
               status: "started",
               profile: "light",
               input_message_ids: [],
               request_context: request_context
             } = Repo.get!(LlmTurn, compression_turn.id)

      refute Map.has_key?(request_context, "compression")

      assert_receive {:actor_lane, compression_envelope}
      compression_start = compression_envelope["body"]["turn_start"]
      compression_ref = compression_start["turn"]
      compression_input_ids = Enum.map(compression_start["inputs"], & &1["actor_input_id"])

      assert compression_ref["llm_turn_id"] == compression_turn.id
      assert compression_start["model_ref"]["profile"] == "light"
      assert [%{"payload_json" => compression_payload}] = compression_start["inputs"]
      assert get_in(compression_payload, ["data", "command", "name"]) == "compress"
      assert get_in(compression_payload, ["data", "command", "argsText"]) == ""
      assert get_in(compression_payload, ["data", "compression"]) == %{}
      refute get_in(compression_payload, ["data", "internal", "text"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => compression_ref,
                   "accepted_actor_input_ids" => compression_input_ids
                 }
               })

      assert {:ok, %{status: :committed, assistant_message: summary_message}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => compression_ref,
                   "messages" => [],
                   "reply" => %{"text" => "Compressed summary for PING and PONG."}
                 }
               })

      assert %Message{kind: "summary", content: [%{"text" => summary_text}]} =
               Repo.get!(Message, summary_message.id)

      assert summary_text == "Compressed summary for PING and PONG."
      assert Repo.get!(LlmTurn, compression_turn.id).status == "succeeded"
      assert Repo.get!(LlmTurn, generation_turn.id).status == "succeeded"

      assert %ActorInputConsumption{type: "command.compress", llm_turn_id: compression_turn_id} =
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
    end

    test "retry command queues a retry generation without command feedback" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: _input}} =
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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

    test "inactive steer command starts a generation with the steer args" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: steer_input}} =
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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

      assert Repo.one!(
               from(message in Message,
                 where: message.kind == "introspection",
                 select: message.event_source
               )
             ) == "ai_agent.command.steer"

      assert Repo.aggregate(LlmTurn, :count) == 1
    end

    test "stop command cancels active generation and rejects late final proposal" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/stop", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert stop_input.type == "command.stop"

      assert {:ok, %{status: :command_consumed, feedback: "Stopped."}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

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

    test "record_only input does not start an actor turn or emit PONG" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{status: :recorded}} =
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
      assert assignment.worker_instance_id == ready_worker.worker_instance_id
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry(
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

    test "recalled input rejects late final proposal without provider output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
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
               SignalsGateway.emit_entry_recalled(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   ingress_event_id: "recall-before-final",
                   signal_channel_id: input.signal_channel_id,
                   provider_entry_id: input.provider_entry_id,
                   provider_thread_id: input.provider_thread_id
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:error, :no_accepted_delivery} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert Repo.get!(LlmTurn, llm_turn.id).status == "started"
      refute Repo.get(ActorInput, input.id)

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "watchdog supersedes stale unaccepted delivery and retries through another worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      stale_route = unique_route()
      live_route = unique_route()

      :ok = Broker.register_local_worker(stale_route, self())
      on_exit(fn -> Broker.unregister_local_worker(stale_route) end)

      assert {:ok, stale_worker} = admit_worker(stale_route)

      Repo.update_all(
        from(worker in AgentComputerWorker, where: worker.worker_id == ^stale_worker.worker_id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 300
               )

      assert_receive {:actor_lane, _first_envelope}
      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      assert {:ok, %{stale_workers: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60
               )

      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert %ActorInputDelivery{state: "superseded"} =
               Repo.one!(
                 from(delivery in ActorInputDelivery,
                   where: delivery.actor_input_id == ^input.id
                 )
               )

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, live_worker} = admit_worker(live_route)

      assert {:ok, %{llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 121, :second))

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"

      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == second_turn.id

      assert %ActorSessionActivation{
               assigned_worker_id: assigned_worker_id,
               current_llm_turn_id: current_llm_turn_id
             } =
               Repo.one!(from(activation in ActorSessionActivation))

      assert assigned_worker_id == live_worker.worker_id
      assert current_llm_turn_id == second_turn.id

      assert ["sent"] =
               ActorInputDelivery
               |> where([delivery], delivery.actor_input_id == ^input.id)
               |> order_by([delivery], asc: delivery.attempt_no)
               |> select([delivery], delivery.state)
               |> Repo.all()
    end

    test "watchdog deletes stale worker projections after the v1 ttl" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      Repo.update_all(
        from(stored_worker in AgentComputerWorker, where: stored_worker.id == ^worker.id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %{stale_workers: 1, deleted_stale_workers: 0}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60,
                 stale_worker_ttl_seconds: 3_600
               )

      assert %AgentComputerWorker{status: "stale"} = Repo.get!(AgentComputerWorker, worker.id)

      assert {:ok, %{stale_workers: 0, deleted_stale_workers: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 3_700, :second),
                 stale_after_seconds: 60,
                 stale_worker_ttl_seconds: 3_600
               )

      refute Repo.get(AgentComputerWorker, worker.id)
    end

    test "projection loss reconciles old started turn and creates retry generation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_lane, first_envelope}
      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      Repo.delete_all(ActorInputDelivery)
      Repo.delete_all(ActorSessionActivation)

      assert {:ok, 1} =
               ActorRuntime.reconcile_projection_lost_started_turns(
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert {:error, :llm_turn_not_started} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => first_turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert {:ok, %{llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"
      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == second_turn.id
    end

    test "reconciler runs a startup projection-loss pass" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: started_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_lane, _envelope}

      Repo.delete_all(ActorInputDelivery)
      Repo.delete_all(ActorSessionActivation)

      start_supervised!({Reconciler, name: unique_process_name("reconciler")})

      assert %LlmTurn{status: "failed"} = wait_for_turn_status(started_turn.id, "failed")
      assert Repo.get!(ActorInput, input.id).input_state == "open"
    end

    test "channel reply mode uses post outbox operation when entry reply is unavailable" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   text: "PING",
                   explicit: true,
                   channel: %{kind: :im_group, reply_mode: :channel, name: "Ops"}
                 }),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")
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

      llm_turn_id = llm_turn.id

      assert %OutboxEntry{operation: :post, llm_turn_id: ^llm_turn_id} =
               Repo.one!(from(outbox in OutboxEntry))
    end

    test "broker uses ZeroMQ mandatory route outcome when router is running" do
      assert {:ok, endpoint} =
               Broker.start_router("tcp://127.0.0.1:*",
                 pre_auth_token: "test-token",
                 poll_interval_ms: 1
               )

      on_exit(fn -> Broker.stop_router() end)

      assert endpoint =~ "tcp://"

      assert {:error, :unknown_route} =
               Broker.send_mandatory("missing-worker", worker_ready_envelope())
    end

    test "worker heartbeat and capacity update only the authenticated worker projection" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:ok, heartbeat_worker} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "worker_instance_id" => worker.worker_instance_id,
                   "monotonic_ms" => 123,
                   "load_json" => %{"active_turns" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert heartbeat_worker.load == %{"active_turns" => 1}

      assert {:ok, capacity_worker} =
               ActorRuntime.handle_worker_capacity(
                 %{
                   "worker_id" => worker.worker_id,
                   "worker_instance_id" => worker.worker_instance_id,
                   "available_turn_slots" => 2,
                   "capacity_json" => %{"available_turn_slots" => 2},
                   "load_json" => %{"active_turns" => 0}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert capacity_worker.capacity == %{"available_turn_slots" => 2}
      assert capacity_worker.load == %{"active_turns" => 0}

      assert {:error, :stale_transport_route} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "worker_instance_id" => worker.worker_instance_id
                 },
                 %{authenticated?: true, transport_route: route <> "-stale"}
               )
    end

    test "broker rejects worker actor lane writes from an unassigned route" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()
      wrong_route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
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
      accepted_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")
      assert {:ok, _wrong_worker} = admit_worker(wrong_route)

      accepted_envelope = %{
        "protocol_version" => 1,
        "message_id" => "turn-accepted-wrong-route",
        "correlation_id" => envelope["message_id"],
        "lane" => "LANE_TURN",
        "durability" => "CONTROL_REPLAYABLE",
        "body" => %{
          "type" => "turn_accepted",
          "turn_accepted" => %{
            "turn" => turn_ref,
            "accepted_actor_input_ids" => accepted_ids
          }
        }
      }

      send(
        Broker,
        {:runtime_fabric_router_received, wrong_route, nil, nil,
         Torque.encode!(accepted_envelope)}
      )

      :sys.get_state(Broker)

      assert %ActorInputDelivery{state: "sent"} =
               Repo.get_by!(ActorInputDelivery, actor_input_id: input.id)

      send(
        Broker,
        {:runtime_fabric_router_received, route, nil, nil, Torque.encode!(accepted_envelope)}
      )

      :sys.get_state(Broker)

      assert %ActorInputDelivery{state: "accepted"} =
               Repo.get_by!(ActorInputDelivery, actor_input_id: input.id)
    end

    test "worker admission rejects duplicate live instance and route ownership" do
      route = unique_route()
      duplicate_route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:error, :duplicate_worker_instance} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "other-worker-instance",
                   worker_instance_id: worker.worker_instance_id,
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: duplicate_route}
               )

      assert {:error, :duplicate_worker_route} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "other-worker-route",
                   worker_instance_id: "other-worker-route-instance",
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:ok, refreshed_worker} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: worker.worker_id,
                   worker_instance_id: "refreshed-" <> worker.worker_instance_id,
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 2}
                 },
                 %{authenticated?: true, transport_route: duplicate_route}
               )

      assert refreshed_worker.worker_id == worker.worker_id
      assert refreshed_worker.worker_instance_id == "refreshed-" <> worker.worker_instance_id
      assert refreshed_worker.transport_route == duplicate_route
    end

    test "worker admission requires runtime and version identity fields" do
      route = unique_route()

      assert {:error, {:missing, "runtime"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-runtime",
                   worker_instance_id: "worker-missing-runtime-instance",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:error, {:missing, "version"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-version",
                   worker_instance_id: "worker-missing-version-instance",
                   runtime: "bun",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert Repo.aggregate(AgentComputerWorker, :count) == 0
    end

    test "worker bootstrap renders an operator command without actor-specific args" do
      assert {:ok, command} =
               WorkerBootstrap.docker_run_command(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-a",
                 worker_instance_id: "worker-a-1"
               )

      assert command =~ "docker run --rm"
      assert command =~ "ANKOLE_RUNTIME_FABRIC_ENDPOINT"
      refute command =~ "DATABASE_URL"
      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_ID"
      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN"
      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID"
      assert command =~ "ANKOLE_WORKSPACE_ROOT=/workspace"
      assert command =~ "ANKOLE_WORKSPACE_SESSIONS_ROOT=/workspace/.sessions"
      assert command =~ "ANKOLE_SHARED_FS_ROOT"
      assert command =~ "/workspace/shared"
      assert command =~ "ANKOLE_USER_FILES_ROOT"
      assert command =~ "/workspace/shared/user-files"
      assert command =~ "ANKOLE_AGENT_INSTALLED_SKILLS_ROOT"
      assert command =~ "/workspace/shared/skills/agents"
      assert command =~ "ANKOLE_BUILTIN_SKILLS_ROOT"
      assert command =~ "/repo/app/library/skills"
      assert command =~ ":/workspace/shared"
      assert command =~ ":/workspace/.sessions"
      refute command =~ "ANKOLE_TIGERFS_MOUNT_ROOT"
      refute command =~ "--device /dev/fuse"
      refute command =~ "--cap-add SYS_ADMIN"
      refute command =~ ":/workspace/library-containers"
      refute command =~ "ANKOLE_AGENT_UID"
      refute command =~ "--agent-uid"
    end

    test "worker bootstrap creates a worker pre-auth key without exposing Postgres" do
      assert {:ok, command} =
               WorkerBootstrap.docker_run_command(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-token",
                 worker_instance_id: "worker-token-1"
               )

      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN"
      refute command =~ "DATABASE_URL"

      assert auth_key =
               Repo.get(Ankole.ActorRuntime.Schemas.AgentComputerWorkerAuthKey, "worker-token")

      assert command =~ auth_key.pre_auth_key
    end
  end

  defp admit_worker(route, overrides \\ %{}) do
    ActorRuntime.admit_worker_ready(
      Map.merge(
        %{
          worker_id: "worker-" <> route,
          worker_instance_id: "instance-" <> route,
          runtime: "bun",
          version: "test",
          capacity: %{"available_turn_slots" => 4}
        },
        overrides
      ),
      %{authenticated?: true, transport_route: route}
    )
  end

  defp agent_fixture(attrs \\ %{}) do
    %{principal: agent} = fixture = Ankole.PrincipalsFixtures.agent_fixture(attrs)
    provider_id = "actor-runtime-test-" <> Ecto.UUID.generate()

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: provider_id,
               provider_source: "openrouter",
               credential: "sk-test",
               connection_options: %{"base_url" => "https://openrouter.ai/api/v1"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "google/gemini-3.5-flash"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: provider_id,
               model: "openai/gpt-5.4-nano"
             })

    fixture
  end

  defp binding_fixture(agent_uid, name, policy) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: "lark",
        config_ref: "app-config://#{name}",
        filters: %{},
        unaddressed_group_message_policy: policy
      })

    binding
  end

  defp group_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "evt-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "PING",
        explicit: false,
        author: %{principal_uid: "alice", id: "ou_alice", display_name: "Alice"},
        provider_time: @base_time
      },
      overrides
    )
  end

  defp lifecycle_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "lifecycle-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  defp unique_route do
    "local-test-route-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp unique_process_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp worker_ready_envelope do
    %{
      "protocol_version" => 1,
      "message_id" => "worker-ready-test",
      "lane" => "LANE_CONTROL",
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "worker_ready",
        "worker_ready" => %{
          "worker_id" => "worker-a",
          "worker_instance_id" => "worker-a-1",
          "runtime" => "bun",
          "version" => "test"
        }
      }
    }
  end

  defp wait_for_delivery_state(actor_input_id, state, attempts \\ 100)

  defp wait_for_delivery_state(actor_input_id, state, attempts) when attempts > 0 do
    case Repo.get_by(ActorInputDelivery, actor_input_id: actor_input_id, state: state) do
      %ActorInputDelivery{} = delivery ->
        delivery

      nil ->
        Process.sleep(10)
        wait_for_delivery_state(actor_input_id, state, attempts - 1)
    end
  end

  defp wait_for_delivery_state(actor_input_id, state, 0) do
    flunk("delivery #{actor_input_id} did not reach #{state}")
  end

  defp wait_for_turn_status(llm_turn_id, status, attempts \\ 100)

  defp wait_for_turn_status(llm_turn_id, status, attempts) when attempts > 0 do
    case Repo.get!(LlmTurn, llm_turn_id) do
      %LlmTurn{status: ^status} = turn ->
        turn

      %LlmTurn{} ->
        Process.sleep(10)
        wait_for_turn_status(llm_turn_id, status, attempts - 1)
    end
  end

  defp wait_for_turn_status(llm_turn_id, status, 0) do
    flunk("llm turn #{llm_turn_id} did not reach #{status}")
  end
end
