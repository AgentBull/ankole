defmodule Ankole.SignalsGateway.ActorRuntime.ConversationCommandTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.Schemas.CompactionArtifact

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  describe "conversation and summary commands" do
    test "/compress is parsed as command.compress for the worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      initial_message_count = Repo.aggregate(Message, :count)

      assert {:ok, %{actor_event: input}} =
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
      assert Repo.get(ActorEvent, input.id)
      assert Repo.aggregate(OutboxEntry, :count) == 0
      assert Repo.aggregate(Message, :count) == initial_message_count
    end

    test "/compress writes an AIGateway compaction artifact and feedback outbox" do
      %{principal: agent} = agent_fixture()
      compact_below(1)
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      test_pid = self()

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          send(test_pid, {:gateway_request, request})

          {:sse, 200,
           Ankole.AIGatewayCase.openai_response_stream_events(
             "resp_manual_compaction_summary",
             "gpt-compress",
             "## Active Task\nManual compressed history.",
             %{"total_tokens" => 7}
           )}
        end)

      provider_id = "compress-summary-" <> Ecto.UUID.generate()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-compress"}]
                 }
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "light", %{
                 provider_id: provider_id,
                 model: "gpt-compress"
               })

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.uid, "signal-channel:lark:chat:group-a")

      old =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          nil,
          [%{"type" => "text", "text" => "old text item should be compactable"}]
        )

      middle =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          old.id,
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "middle answer"}]
            }
          ]
        )

      tail =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          middle.id,
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "recent tail"}]
            }
          ]
        )

      assert {:ok, %{actor_event: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Conversation compressed.",
                message: %Message{} = compaction
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:gateway_request, request}
      assert request.path == "v1/responses"

      assert compaction.type == "checkpoint"
      assert compaction.status == "complete"
      assert compaction.previous_message_id == tail.id
      assert compaction.metadata["manual"] == true
      assert compaction.metadata["auto"] == false
      assert compaction.content == [CompactionArtifacts.ref_item(compaction.id)]

      assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

      assert get_in(artifact.content, ["summary", "text"]) ==
               "## Active Task\nManual compressed history."

      assert %DateTime{} = Repo.get!(ActorEvent, compress_event.id).completed_at

      assert %OutboxEntry{payload: %{"text" => "Conversation compressed."}} =
               Repo.get_by!(OutboxEntry,
                 source_actor_event_id: compress_event.id,
                 ai_message_id: compaction.id
               )

      refute_receive {:actor_lane, _envelope}, 100
    end

    test "/compress compacts real Responses role/content text items from live turns" do
      %{principal: agent} = agent_fixture()
      compact_below(1)
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      test_pid = self()

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          send(test_pid, {:gateway_request, request})

          {:sse, 200,
           Ankole.AIGatewayCase.openai_response_stream_events(
             "resp_real_role_content_compaction_summary",
             "gpt-compress",
             "## Active Task\nReal role/content history compressed.",
             %{"total_tokens" => 7}
           )}
        end)

      provider_id = "compress-real-role-content-" <> Ecto.UUID.generate()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-compress"}]
                 }
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "light", %{
                 provider_id: provider_id,
                 model: "gpt-compress"
               })

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.uid, "signal-channel:lark:chat:group-a")

      old =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          nil,
          [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "input_text", "text" => "phase code ANKOLE_REAL_E2E"}
              ]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "recorded"}]
            }
          ]
        )

      middle =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          old.id,
          [
            %{
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "window is Wednesday 19:30"}]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "recorded"}]
            }
          ]
        )

      _tail =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          middle.id,
          [
            %{
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "owner is Ada"}]
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "recorded"}]
            }
          ]
        )

      assert {:ok, %{actor_event: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Conversation compressed.",
                message: %Message{} = compaction
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:gateway_request, request}
      assert request.path == "v1/responses"
      assert request.body["input"] =~ "phase code ANKOLE_REAL_E2E"

      assert compaction.type == "checkpoint"
      assert compaction.previous_message_id != nil
      assert compaction.content == [CompactionArtifacts.ref_item(compaction.id)]

      assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

      assert get_in(artifact.content, ["summary", "text"]) ==
               "## Active Task\nReal role/content history compressed."

      assert %DateTime{} = Repo.get!(ActorEvent, compress_event.id).completed_at
    end

    test "/compress waits for an active generation before compacting history" do
      %{principal: agent} = agent_fixture()
      compact_below(1)
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()
      test_pid = self()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          send(test_pid, {:gateway_request, request})

          {:sse, 200,
           Ankole.AIGatewayCase.openai_response_stream_events(
             "resp_deferred_manual_compaction_summary",
             "gpt-compress",
             "## Active Task\nDeferred compressed history.",
             %{"total_tokens" => 7}
           )}
        end)

      provider_id = "compress-deferred-summary-" <> Ecto.UUID.generate()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-compress"}]
                 }
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "light", %{
                 provider_id: provider_id,
                 model: "gpt-compress"
               })

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.uid, "signal-channel:lark:chat:group-a")

      old =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          nil,
          [%{"type" => "text", "text" => "old text item should be compactable"}]
        )

      middle =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          old.id,
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "middle answer"}]
            }
          ]
        )

      tail =
        insert_complete_message!(
          agent.uid,
          conversation.id,
          middle.id,
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "recent tail"}]
            }
          ]
        )

      assert {:ok, %{actor_event: active_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "active question", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, active_envelope}
      active_turn_ref = turn_start_payload!(active_envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(active_turn_ref))

      {:ok, active_run} =
        StatefulResponses.start_response_run(%{
          subject_uid: agent.uid,
          previous_response_id: "resp_#{tail.id}",
          metadata: %{"request_metadata" => %{"actor_event_id" => active_input.id}},
          request_items: [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "active question"}]
            }
          ]
        })

      assert {:ok, %{actor_event: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok,
              %{
                status: :waiting_for_generation,
                command: "command.compress",
                actor_event: %ActorEvent{id: compress_event_id}
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert compress_event_id == compress_event.id
      assert is_nil(Repo.get!(ActorEvent, compress_event.id).completed_at)
      refute Repo.exists?(from(message in Message, where: message.type == "checkpoint"))
      refute_receive {:gateway_request, _request}, 100

      committed = complete_aigateway_turn!(active_turn_ref, "fresh answer", run: active_run)
      assert_turn_completed(active_turn_ref, committed)

      assert %DateTime{} = Repo.get!(ActorEvent, active_input.id).completed_at

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Conversation compressed.",
                message: %Message{} = compaction
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

      assert_receive {:gateway_request, _request}
      assert compaction.type == "checkpoint"
      assert compaction.content == [CompactionArtifacts.ref_item(compaction.id)]

      assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, compaction.id)

      assert get_in(artifact.content, ["summary", "text"]) ==
               "## Active Task\nDeferred compressed history."

      assert %DateTime{} = Repo.get!(ActorEvent, compress_event.id).completed_at
    end

    test "/stop is selected ahead of an earlier deferred /compress during active generation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: active_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "active question", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, active_envelope}
      active_turn_ref = turn_start_payload!(active_envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(active_turn_ref))

      assert {:ok, %{actor_event: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :waiting_for_generation, command: "command.compress"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert {:ok, %{actor_event: stop_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/stop", explicit: true}),
                 now: DateTime.add(@base_time, 4, :second)
               )

      assert {:ok,
              %{
                status: :command_consumed,
                command: "command.stop",
                feedback: "Stopped.",
                stop_control_outcomes: [%{send_outcome: "sent_or_queued"}]
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

      assert_receive {:actor_lane, stop_control}
      assert envelope_body!(stop_control, :turn_control).command == "stop"
      assert envelope_body!(stop_control, :turn_control).turn.actor_event_id == active_input.id

      assert is_nil(Repo.get!(ActorEvent, compress_event.id).completed_at)
      assert Repo.get!(ActorEvent, compress_event.id).input_state == "open"
      assert %DateTime{} = Repo.get!(ActorEvent, stop_event.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, active_input.id).completed_at
    end

    test "/compress consumes the command when there is no compactable prefix" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      initial_message_count = Repo.aggregate(Message, :count)

      {:ok, _conversation} =
        StatefulResponses.ensure_conversation(agent.uid, "signal-channel:lark:chat:group-a")

      assert {:ok, %{actor_event: compress_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/compress", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Nothing to compress."
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert %DateTime{} = Repo.get!(ActorEvent, compress_event.id).completed_at

      assert %OutboxEntry{payload: %{"text" => "Nothing to compress."}} =
               Repo.get_by!(OutboxEntry, source_actor_event_id: compress_event.id)

      assert Repo.aggregate(Message, :count) == initial_message_count
      refute_receive {:gateway_request, _request}, 100
      refute_receive {:actor_lane, _envelope}, 100
    end

    test "new command with args rolls over the window and starts a generation from the args" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: _first_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "old task", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{conversation: first_conversation}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, first_envelope}
      first_turn_ref = turn_start_payload!(first_envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(first_turn_ref))

      committed = complete_aigateway_turn!(first_turn_ref, "old answer")
      assert_turn_completed(first_turn_ref, committed)
      dispatch_final_reply_outbox!(committed.id)

      assert {:ok, %{actor_event: %ActorEvent{}}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new fresh task\nwith context", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", conversation: next_conversation}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert next_conversation.id != first_conversation.id
      assert Repo.get!(Conversation, first_conversation.id).ended_at
      refute Repo.get_by(Message, conversation_id: first_conversation.id, status: "retracted")

      assert_receive {:actor_lane, next_envelope}
      payload = decoded_json_bytes(turn_start_payload!(next_envelope).actor_event.payload_json)
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh task\nwith context"
    end

    test "new command with args stops an active generation before starting the next window" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: old_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "old active task", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{conversation: old_conversation}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, old_envelope}
      old_start = turn_start_payload!(old_envelope)
      old_turn_ref = old_start.turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(old_turn_ref))

      old_run = start_aigateway_run_for_turn!(old_turn_ref)
      :ok = Events.subscribe(agent.uid, old_conversation.id)

      assert :ok =
               Actors.record_reply_preview_source_entry(old_input.id, "old-preview-message")

      assert {:ok, %{actor_event: new_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new fresh active task", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", conversation: new_conversation}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:ai_gateway_event, :response_failed, event}
      assert event.response_id == "resp_#{old_run.id}"
      assert event.metadata["actor_event_id"] == old_input.id
      assert event.payload.error["code"] == "command.new"
      assert event.payload.error["stage"] == "actor_runtime_cancel"

      assert_receive {:actor_lane, stop_control}
      assert envelope_body_type(stop_control) == :turn_control
      assert envelope_body!(stop_control, :turn_control).command == "stop"

      assert envelope_body!(stop_control, :turn_control).turn.actor_event_id ==
               old_turn_ref.actor_event_id

      assert decoded_json_bytes(envelope_body!(stop_control, :turn_control).payload_json)[
               "reason"
             ] == "command.new"

      assert_receive {:actor_lane, new_envelope}
      new_start = turn_start_payload!(new_envelope)

      assert %FabricProto.ActorEventEnvelope{
               actor_event_id: new_input_id,
               payload_json: payload_json
             } =
               new_start.actor_event

      payload = decoded_json_bytes(payload_json)

      assert new_input_id == new_input.id
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh active task"

      assert new_conversation.id != old_conversation.id
      assert Repo.get!(Conversation, old_conversation.id).ended_at
      refute Repo.get_by(Message, conversation_id: old_conversation.id, status: "retracted")
      assert Repo.get!(Message, old_run.id).status == "error"
      assert %DateTime{} = Repo.get!(ActorEvent, old_input.id).completed_at
      assert Repo.get!(ActorEvent, new_input.id).input_state == "open"

      stopped_outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "ai-turn-stopped:#{old_input.id}"
        )

      assert stopped_outbox.operation == :edit
      assert stopped_outbox.target_source_entry_id == "old-preview-message"
      assert stopped_outbox.delivery_class == :durable_ai_reply
      assert get_in(stopped_outbox.payload, ["reply_presentation", "state"]) == "stopped"
      assert get_in(stopped_outbox.payload, ["reply_presentation", "answer"]) == ""
      assert get_in(stopped_outbox.payload, ["metadata", "source"]) == "actor_turn_stopped"
      assert get_in(stopped_outbox.payload, ["metadata", "reason"]) == "command.new"
    end

    test "new command with args waits for a worker and is retried as an open input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

      assert {:ok, old_conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(
                 agent.uid,
                 "signal-channel:lark:chat:group-a"
               )

      assert {:ok, %{actor_event: new_input}} =
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
               process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorEvent, new_input.id).input_state == "open"
      assert Repo.get!(Conversation, old_conversation.id).ended_at
      refute Repo.get_by(Message, conversation_id: old_conversation.id, status: "retracted")
      assert Repo.aggregate(ActorEventDelivery, :count) == 0

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{send_outcome: "sent_or_queued", conversation: next_conversation}} =
               process_ready_events_once(now: DateTime.add(@base_time, 2, :second))

      assert next_conversation.id != old_conversation.id

      assert_receive {:actor_lane, next_envelope}
      payload = decoded_json_bytes(turn_start_payload!(next_envelope).actor_event.payload_json)
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh task after worker returns"
    end

    test "/new consumes a retryable turn whose delivery failed during reset" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: old_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "old stalled task", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{conversation: old_conversation}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, old_envelope}
      old_turn_ref = turn_start_payload!(old_envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(old_turn_ref))

      old_run =
        start_aigateway_run_for_turn!(old_turn_ref,
          request_items: [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "old stalled task"}]
            }
          ]
        )

      assert :ok = Actors.record_reply_preview_source_entry(old_input.id, "old-preview-message")

      assert {:ok, _failed_response} =
               StatefulResponses.commit_error(
                 old_run,
                 [
                   %{
                     "type" => "message",
                     "role" => "assistant",
                     "content" => [%{"type" => "output_text", "text" => "partial answer"}]
                   }
                 ],
                 %{"code" => "socket_terminated", "retryable" => true}
               )

      assert {:ok, %{status: :turn_failed, retry_available_at: retry_available_at}} =
               ActorRuntime.handle_turn_error(
                 turn_error_payload(
                   old_turn_ref,
                   "worker_turn_failed",
                   "AIGateway socket closed before terminal",
                   %{"retryable" => true}
                 ),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert %DateTime{} = retry_available_at
      assert is_nil(Repo.get!(ActorEvent, old_input.id).completed_at)
      assert Repo.get_by!(ActorEventDelivery, actor_event_id: old_input.id).state == "superseded"

      assert {:ok, %{actor_event: new_command}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new", explicit: true}),
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert {:ok,
              %{
                status: :command_consumed,
                command: "command.new",
                feedback: "Started a new conversation."
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert %DateTime{} = Repo.get!(ActorEvent, old_input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, new_command.id).completed_at
      assert %DateTime{} = Repo.get!(Conversation, old_conversation.id).ended_at

      stopped_outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: "ai-turn-stopped:#{old_input.id}"
        )

      assert stopped_outbox.target_source_entry_id == "old-preview-message"
      assert get_in(stopped_outbox.payload, ["reply_presentation", "state"]) == "stopped"
      assert get_in(stopped_outbox.payload, ["metadata", "reason"]) == "command.new"

      assert {:ok, %{status: :idle}} =
               process_ready_events_once(now: DateTime.add(retry_available_at, 1, :second))

      refute_receive {:actor_lane, _redelivered_old_turn}, 100
    end
  end

  defp insert_complete_message!(agent_uid, conversation_id, previous_message_id, content) do
    {:ok, actor_event} =
      append_runtime_actor_event(agent_uid, "compress-history", "im.message.addressed",
        now: DateTime.utc_now(:microsecond)
      )

    attrs = %{
      subject_uid: agent_uid,
      metadata: %{"request_metadata" => %{"actor_event_id" => actor_event.id}},
      request_items: content
    }

    attrs =
      case previous_message_id do
        nil -> Map.put(attrs, :conversation_id, conversation_id)
        message_id -> Map.put(attrs, :previous_response_id, "resp_#{message_id}")
      end

    {:ok, message} = StatefulResponses.start_response_run(attrs)
    {:ok, message} = StatefulResponses.commit_complete(message, [])

    message
  end

  defp assert_turn_completed(turn_ref, message) do
    assert {:ok, %{status: :turn_completed}} =
             ActorRuntime.handle_turn_completed(
               turn_completed_payload(turn_ref, "resp_#{message.id}", "loop_finished")
             )
  end

  # These conversations are a few turns long, so the retained tail must stay
  # below them for a prefix to exist. What is under test is the command path,
  # not the row floor.
  defp compact_below(tail_rows) do
    merged = Map.put(Ankole.AIGateway.Compaction.config(), "tail_rows", tail_rows)
    assert {:ok, _config} = Ankole.AIGateway.Compaction.put_config(merged)

    on_exit(fn ->
      _result = Ankole.AIGateway.Compaction.delete_config()
      :ok
    end)
  end
end
