defmodule Ankole.ActorRuntime.ConversationCommandTest do
  use Ankole.ActorRuntimeCase

  setup {Ankole.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  describe "conversation and summary commands" do
    test "/compress is parsed as command.compress for the worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

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
      assert Repo.aggregate(Message, :count) == 0
    end

    test "/compress writes an AIGateway compaction fact and feedback outbox" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      test_pid = self()

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          send(test_pid, {:gateway_request, request})

          {:json, 200,
           %{
             "id" => "resp_manual_compaction_summary",
             "object" => "response",
             "status" => "completed",
             "output" => [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "Manual compressed history."}
                 ]
               }
             ],
             "usage" => %{"total_tokens" => 7}
           }}
        end)

      provider_id = "compress-summary-" <> Ecto.UUID.generate()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 connection_options: %{"api_key" => "sk-compress"}
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

      assert compaction.type == "compaction"
      assert compaction.status == "complete"
      assert compaction.previous_message_id == tail.id
      assert compaction.covers_until_message_id == old.id
      assert compaction.metadata["manual"] == true
      assert compaction.metadata["auto"] == false

      assert [%{"type" => "compaction", "summary" => "Manual compressed history."}] =
               compaction.content

      assert %DateTime{} = Repo.get!(ActorEvent, compress_event.id).completed_at

      assert %OutboxEntry{payload: %{"text" => "Conversation compressed."}} =
               Repo.get_by!(OutboxEntry,
                 source_actor_event_id: compress_event.id,
                 ai_message_id: compaction.id
               )

      refute_receive {:actor_lane, _envelope}, 100
    end

    test "/compress waits for an active generation before compacting history" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()
      test_pid = self()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      base_url =
        Ankole.AIGatewayCase.start_upstream_server(fn request ->
          send(test_pid, {:gateway_request, request})

          {:json, 200,
           %{
             "id" => "resp_deferred_manual_compaction_summary",
             "object" => "response",
             "status" => "completed",
             "output" => [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "Deferred compressed history."}
                 ]
               }
             ],
             "usage" => %{"total_tokens" => 7}
           }}
        end)

      provider_id = "compress-deferred-summary-" <> Ecto.UUID.generate()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: provider_id,
                 provider_kind: "openai",
                 base_url: "#{base_url}/v1",
                 connection_options: %{"api_key" => "sk-compress"}
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
      active_turn_ref = active_envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => active_turn_ref}
               })

      {:ok, active_run} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.uid,
          actor_event_id: active_input.id,
          previous_response_id: "resp_#{tail.id}",
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
      refute Repo.exists?(from(message in Message, where: message.type == "compaction"))
      refute_receive {:gateway_request, _request}, 100

      complete_aigateway_turn!(active_turn_ref, "fresh answer", run: active_run)

      assert %DateTime{} = Repo.get!(ActorEvent, active_input.id).completed_at

      assert {:ok,
              %{
                status: :command_consumed,
                feedback: "Conversation compressed.",
                message: %Message{} = compaction
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

      assert_receive {:gateway_request, _request}
      assert compaction.type == "compaction"

      assert [%{"type" => "compaction", "summary" => "Deferred compressed history."}] =
               compaction.content

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
      active_turn_ref = active_envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => active_turn_ref}
               })

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
      assert stop_control["body"]["turn_control"]["command"] == "stop"
      assert stop_control["body"]["turn_control"]["turn"]["actor_event_id"] == active_input.id

      assert is_nil(Repo.get!(ActorEvent, compress_event.id).completed_at)
      assert Repo.get!(ActorEvent, compress_event.id).input_state == "open"
      assert %DateTime{} = Repo.get!(ActorEvent, stop_event.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, active_input.id).completed_at
    end

    test "/compress consumes the command when there is no compactable prefix" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

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

      assert Repo.aggregate(Message, :count) == 0
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
      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => first_turn_ref
                 }
               })

      complete_aigateway_turn!(first_turn_ref, "old answer", wait_for_mirror: true)

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
      assert %{"payload_json" => payload} = next_envelope["body"]["turn_start"]["actor_event"]
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
      old_start = old_envelope["body"]["turn_start"]
      old_turn_ref = old_start["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => old_turn_ref
                 }
               })

      old_run = start_aigateway_run_for_turn!(old_turn_ref)
      :ok = StatefulResponses.subscribe(old_input.id)

      assert {:ok, %{actor_event: new_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/new fresh active task", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{send_outcome: "sent_or_queued", conversation: new_conversation}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:ai_gateway_event, :response_failed, message_id, payload}
      assert message_id == old_run.id
      assert payload.message_id == old_run.id
      assert payload.response_id == "resp_#{old_run.id}"
      assert payload.actor_event_id == old_input.id
      assert payload.error["code"] == "command.new"
      assert payload.error["stage"] == "actor_runtime_cancel"

      assert_receive {:actor_lane, stop_control}
      assert stop_control["body"]["type"] == "turn_control"
      assert stop_control["body"]["turn_control"]["command"] == "stop"

      assert stop_control["body"]["turn_control"]["turn"]["actor_event_id"] ==
               old_turn_ref["actor_event_id"]

      assert stop_control["body"]["turn_control"]["payload_json"]["reason"] == "command.new"

      assert_receive {:actor_lane, new_envelope}
      new_start = new_envelope["body"]["turn_start"]

      assert %{"actor_event_id" => new_input_id, "payload_json" => payload} =
               new_start["actor_event"]

      assert new_input_id == new_input.id
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh active task"

      assert new_conversation.id != old_conversation.id
      assert Repo.get!(Conversation, old_conversation.id).ended_at
      refute Repo.get_by(Message, conversation_id: old_conversation.id, status: "retracted")
      assert Repo.get!(Message, old_run.id).status == "error"
      assert %DateTime{} = Repo.get!(ActorEvent, old_input.id).completed_at
      assert Repo.get!(ActorEvent, new_input.id).input_state == "open"
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
      assert %{"payload_json" => payload} = next_envelope["body"]["turn_start"]["actor_event"]
      assert get_in(payload, ["data", "command", "argsText"]) == "fresh task after worker returns"
    end
  end

  defp insert_complete_message!(agent_uid, conversation_id, previous_message_id, content) do
    {:ok, actor_event} =
      append_runtime_actor_event(agent_uid, "compress-history", "im.message.addressed",
        now: DateTime.utc_now(:microsecond)
      )

    attrs = %{
      agent_uid: agent_uid,
      actor_event_id: actor_event.id,
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
end
