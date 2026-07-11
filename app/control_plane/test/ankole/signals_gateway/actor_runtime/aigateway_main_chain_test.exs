defmodule Ankole.SignalsGateway.ActorRuntime.AIGatewayMainChainTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.SignalsGateway.Entry

  setup :use_mock_signal_provider_plugin

  test "IM actor event stays live through Responses rounds and completes only after turn_completed" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{actor_event: actor_event} =
      Ankole.SignalsGatewayFixtures.emit_addressed_actor_event(
        agent.uid,
        "mock",
        Ankole.SignalsGatewayFixtures.group_entry(%{
          source_event_id: "main-chain-event",
          signal_channel_id: "mock:chat:main-chain",
          source_entry_id: "human-main-chain-1",
          provider_thread_id: "mock-thread-main-chain",
          explicit: true,
          text: "Need the weather."
        })
      )

    refute preview_handler_started?(actor_event.id)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    preview_handler = wait_for_preview_handler(actor_event.id)
    assert is_pid(preview_handler)

    assert_receive {:actor_lane, envelope}, 2_000
    turn_start = envelope["body"]["turn_start"]
    turn_ref = turn_start["turn"]

    assert turn_ref["actor"]["agent_uid"] == agent.uid
    assert turn_ref["actor"]["session_id"] == actor_event.session_id
    assert turn_ref["actor_event_id"] == actor_event.id
    assert turn_start["actor_event"]["actor_event_id"] == actor_event.id

    assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{
                 "turn" => turn_ref
               }
             })

    assert live_delivery_count(actor_event.id) == 1

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    first_request_items = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "Need the weather."}]
      }
    ]

    {:ok, first_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: actor_event_metadata(actor_event.id),
        request_items: first_request_items
      })

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_weather",
      "name" => "lookup_weather",
      "arguments" => ~s({"city":"Shanghai"})
    }

    assert {:ok, first_committed} =
             StatefulResponses.commit_complete(first_round, [function_call])

    assert first_committed.previous_message_id == nil
    assert first_committed.content == first_request_items ++ [function_call]
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
    assert live_delivery_count(actor_event.id) == 1
    assert Process.alive?(preview_handler)
    refute_final_mirror(first_committed.id)

    tool_result_items = [
      %{
        "type" => "function_call_output",
        "call_id" => "call_weather",
        "output" => "sunny"
      }
    ]

    {:ok, second_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        metadata: actor_event_metadata(actor_event.id),
        previous_response_id: "resp_#{first_committed.id}",
        request_items: tool_result_items
      })

    assert second_round.conversation_id == conversation.id
    assert second_round.previous_message_id == first_committed.id
    assert second_round.content == tool_result_items

    final_output = [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{"type" => "output_text", "text" => "It is sunny in Shanghai."}
        ]
      }
    ]

    assert {:ok, final_committed} = StatefulResponses.commit_complete(second_round, final_output)

    assert final_committed.content == tool_result_items ++ final_output
    assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
    assert live_delivery_count(actor_event.id) == 1
    assert Process.alive?(preview_handler)
    refute Repo.get_by(OutboxEntry, source_actor_event_id: actor_event.id)

    assert {:ok, %{status: :turn_completed}} =
             complete_turn(turn_ref, final_committed)

    assert %DateTime{} = Repo.get!(ActorEvent, actor_event.id).completed_at
    assert live_delivery_count(actor_event.id) == 0
    refute Process.alive?(preview_handler)

    dispatch_final_reply_outbox!(final_committed.id)
    mirror = wait_for_final_mirror(final_committed.id)
    assert mirror.signal_channel_id == actor_event.signal_channel_id
    assert mirror.text == "It is sunny in Shanghai."
    assert mirror.ai_message_id == final_committed.id
    assert mirror.metadata["actor_event_id"] == actor_event.id
    refute Repo.get_by(Entry, ai_message_id: first_committed.id)
  end

  test "reply_attachment tool output commits a durable outbox row on final response" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    %{actor_event: actor_event, turn_ref: turn_ref} =
      start_accepted_actor_event(agent.uid, %{
        source_event_id: "reply-attachment-main-chain-event",
        signal_channel_id: "mock:chat:reply-attachment",
        source_entry_id: "human-reply-attachment-1",
        provider_thread_id: "mock-thread-reply-attachment",
        explicit: true,
        text: "Attach the report."
      })

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    {:ok, first_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: actor_event_metadata(actor_event.id),
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "Attach the report."
          }
        ]
      })

    assert {:ok, first_committed} =
             StatefulResponses.commit_complete(first_round, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_reply_attachment",
                 "name" => "reply_attachment",
                 "arguments" =>
                   ~s({"path":"/workspace/user-files/reports/chaos-report.txt","name":"chaos-report.txt","mimeType":"text/plain"})
               }
             ])

    attachment = %{
      "agent_computer_path" => "/workspace/user-files/reports/chaos-report.txt",
      "user_files_relative_path" => "reports/chaos-report.txt",
      "name" => "chaos-report.txt",
      "mime_type" => "text/plain",
      "size" => 28
    }

    {:ok, second_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        metadata: actor_event_metadata(actor_event.id),
        previous_response_id: "resp_#{first_committed.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_reply_attachment",
            "output" =>
              untrusted_tool_output(
                Ankole.JSON.encode!(%{
                  "tool" => "reply_attachment",
                  "ok" => true,
                  "attachments" => [attachment]
                })
              )
          }
        ]
      })

    assert {:ok, final_committed} =
             StatefulResponses.commit_complete(second_round, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "CHAOS_REPLY_ATTACHMENT_OK"}
                 ]
               }
             ])

    refute Repo.get_by(OutboxEntry, source_actor_event_id: actor_event.id)

    assert {:ok, %{status: :turn_completed}} =
             complete_turn(turn_ref, final_committed)

    outbox =
      Repo.get_by!(OutboxEntry,
        agent_uid: agent.uid,
        binding_name: "mock",
        outbound_key: "ai-reply-attachment:#{final_committed.id}:0"
      )

    assert outbox.status == :created
    assert outbox.operation == :reply
    assert outbox.source_actor_event_id == actor_event.id
    assert outbox.ai_message_id == final_committed.id
    assert outbox.reply_to_source_entry_id == "human-reply-attachment-1"
    assert outbox.payload["text"] == "CHAOS_REPLY_ATTACHMENT_OK"
    assert outbox.payload["attachments"] == [attachment]

    dispatch_final_reply_outbox!(final_committed.id)
    mirror = wait_for_final_mirror(final_committed.id)
    assert mirror.text == "CHAOS_REPLY_ATTACHMENT_OK"
  end

  test "reply_attachment tool result journal commits attachment outbox on final response" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    %{actor_event: actor_event, turn_ref: turn_ref} =
      start_accepted_actor_event(agent.uid, %{
        source_event_id: "reply-attachment-journal-event",
        signal_channel_id: "mock:chat:reply-attachment-journal",
        source_entry_id: "human-reply-attachment-journal-1",
        provider_thread_id: "mock-thread-reply-attachment-journal",
        explicit: true,
        text: "Create the chart and send it."
      })

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    {:ok, first_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: actor_event_metadata(actor_event.id),
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "Create the chart and send it."
          }
        ]
      })

    assert {:ok, first_committed} =
             StatefulResponses.commit_complete(first_round, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_reply_attachment_journal",
                 "name" => "reply_attachment",
                 "arguments" =>
                   ~s({"path":"/workspace/user-files/charts/sales.png","name":"sales.png","mimeType":"image/png"})
               }
             ])

    attachment = %{
      "agent_computer_path" => "/workspace/user-files/charts/sales.png",
      "user_files_relative_path" => "charts/sales.png",
      "name" => "sales.png",
      "mime_type" => "image/png",
      "size" => 4096
    }

    assert {:ok, journal} =
             StatefulResponses.record_tool_results(%{
               subject_uid: agent.uid,
               metadata: actor_event_metadata(actor_event.id),
               previous_response_id: "resp_#{first_committed.id}",
               request_items: [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_reply_attachment_journal",
                   "output" =>
                     untrusted_tool_output(
                       Ankole.JSON.encode!(%{
                         "tool" => "reply_attachment",
                         "ok" => true,
                         "attachments" => [attachment]
                       })
                     )
                 }
               ]
             })

    assert journal.metadata["tool_result_journal"] == true

    {:ok, final_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        metadata: actor_event_metadata(actor_event.id),
        previous_response_id: "resp_#{journal.id}",
        request_items: []
      })

    assert {:ok, final_committed} =
             StatefulResponses.commit_complete(final_round, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "SALES_CHART_ATTACHED"}
                 ]
               }
             ])

    refute Repo.get_by(OutboxEntry, source_actor_event_id: actor_event.id)

    assert {:ok, %{status: :turn_completed}} =
             complete_turn(turn_ref, final_committed)

    outbox =
      Repo.get_by!(OutboxEntry,
        agent_uid: agent.uid,
        binding_name: "mock",
        outbound_key: "ai-reply-attachment:#{final_committed.id}:0"
      )

    assert outbox.status == :created
    assert outbox.operation == :reply
    assert outbox.source_actor_event_id == actor_event.id
    assert outbox.ai_message_id == final_committed.id
    assert outbox.reply_to_source_entry_id == "human-reply-attachment-journal-1"
    assert outbox.payload["text"] == "SALES_CHART_ATTACHED"
    assert outbox.payload["attachments"] == [attachment]
    refute Repo.get_by(OutboxEntry, outbound_key: "ai-reply-attachment:#{journal.id}:0")

    dispatch_final_reply_outbox!(final_committed.id)
    mirror = wait_for_final_mirror(final_committed.id)
    assert mirror.text == "SALES_CHART_ATTACHED"
  end

  test "clarify tool output replaces the plain final reply with one durable interactive outbox" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    %{actor_event: actor_event, turn_ref: turn_ref} =
      start_accepted_actor_event(agent.uid, %{
        source_event_id: "clarify-main-chain-event",
        signal_channel_id: "mock:chat:clarify",
        source_entry_id: "human-clarify-1",
        provider_thread_id: "mock-thread-clarify",
        explicit: true,
        text: "Prepare the brief."
      })

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    {:ok, first_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: actor_event_metadata(actor_event.id),
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "Prepare the brief."
          }
        ]
      })

    assert {:ok, first_committed} =
             StatefulResponses.commit_complete(first_round, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_clarify_audience",
                 "name" => "clarify",
                 "arguments" =>
                   ~s({"question":"Who should this brief target?","choices":[{"label":"Operators"},{"label":"Executives"}]})
               }
             ])

    {:ok, final_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        metadata: actor_event_metadata(actor_event.id),
        previous_response_id: "resp_#{first_committed.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_clarify_audience",
            "output" =>
              untrusted_tool_output(
                Ankole.JSON.encode!(%{
                  "tool" => "clarify",
                  "ok" => true,
                  "question" => "Who should this brief target?",
                  "choices" => [
                    %{"label" => "Operators"},
                    %{"label" => "Executives"}
                  ]
                })
              )
          }
        ]
      })

    assert {:ok, final_committed} =
             StatefulResponses.commit_complete(final_round, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "I need one decision first."}
                 ]
               }
             ])

    refute Repo.get_by(OutboxEntry, source_actor_event_id: actor_event.id)

    assert {:ok, %{status: :turn_completed}} =
             complete_turn(turn_ref, final_committed)

    outbox =
      Repo.get_by!(OutboxEntry,
        agent_uid: agent.uid,
        binding_name: "mock",
        outbound_key: "ai-reply:#{final_committed.id}"
      )

    assert outbox.status == :created
    assert outbox.operation == :reply
    assert outbox.source_actor_event_id == actor_event.id
    assert outbox.ai_message_id == final_committed.id
    assert outbox.reply_to_source_entry_id == "human-clarify-1"
    assert outbox.payload["metadata"]["source"] == "ai_gateway_clarify"
    assert outbox.payload["text"] =~ "I need one decision first."
    assert outbox.payload["text"] =~ "Who should this brief target?"

    assert Enum.map(outbox.payload["interactive_output"]["choices"], & &1["label"]) ==
             ["Operators", "Executives", "Other / free input"]

    assert Repo.aggregate(
             from(entry in OutboxEntry,
               where:
                 entry.ai_message_id == ^final_committed.id and
                   entry.outbound_key == ^outbox.outbound_key
             ),
             :count
           ) == 1
  end

  defp start_accepted_actor_event(agent_uid, event_attrs) do
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{actor_event: actor_event} =
      Ankole.SignalsGatewayFixtures.emit_addressed_actor_event(
        agent_uid,
        "mock",
        Ankole.SignalsGatewayFixtures.group_entry(event_attrs)
      )

    refute preview_handler_started?(actor_event.id)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    preview_handler = wait_for_preview_handler(actor_event.id)
    assert_receive {:actor_lane, envelope}, 2_000
    turn_ref = envelope["body"]["turn_start"]["turn"]

    assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{"turn" => turn_ref}
             })

    %{
      actor_event: actor_event,
      preview_handler: preview_handler,
      turn_ref: turn_ref
    }
  end

  defp complete_turn(turn_ref, final_response, outcome \\ "loop_finished") do
    ActorRuntime.handle_turn_completed(%{
      "turn_completed" => %{
        "turn" => turn_ref,
        "final_response_id" => "resp_#{final_response.id}",
        "outcome" => outcome
      }
    })
  end

  # StatefulResponses is an internal storage API. The caller-owned metadata
  # object remains opaque under the same request_metadata envelope used by the
  # public Responses lifecycle.
  defp actor_event_metadata(actor_event_id) do
    %{"request_metadata" => %{"actor_event_id" => actor_event_id}}
  end

  defp preview_handler_started?(actor_event_id) do
    Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) != []
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        disabled_ids: MapSet.new()
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp wait_for_preview_handler(actor_event_id, attempts_left \\ 20)

  defp wait_for_preview_handler(actor_event_id, attempts_left) when attempts_left > 0 do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) do
      [{pid, _value}] ->
        pid

      [] ->
        Process.sleep(10)
        wait_for_preview_handler(actor_event_id, attempts_left - 1)
    end
  end

  defp wait_for_preview_handler(actor_event_id, 0) do
    flunk("preview handler for actor_event_id=#{actor_event_id} was not started")
  end

  defp live_delivery_count(actor_event_id) do
    live_states = ActorEventDelivery.live_states()

    Repo.aggregate(
      from(delivery in ActorEventDelivery,
        where: delivery.actor_event_id_fence == ^actor_event_id,
        where: delivery.state in ^live_states
      ),
      :count
    )
  end

  defp wait_for_final_mirror(ai_message_id, attempts_left \\ 20)

  defp wait_for_final_mirror(ai_message_id, attempts_left) when attempts_left > 0 do
    case Repo.get_by(Entry, ai_message_id: ai_message_id) do
      %Entry{} = entry ->
        entry

      nil ->
        Process.sleep(50)
        wait_for_final_mirror(ai_message_id, attempts_left - 1)
    end
  end

  defp wait_for_final_mirror(ai_message_id, 0) do
    flunk("expected final reply mirror for ai_message_id=#{ai_message_id}")
  end

  defp refute_final_mirror(ai_message_id, attempts_left \\ 3)

  defp refute_final_mirror(ai_message_id, attempts_left) when attempts_left > 0 do
    refute Repo.get_by(Entry, ai_message_id: ai_message_id)
    Process.sleep(20)
    refute_final_mirror(ai_message_id, attempts_left - 1)
  end

  defp refute_final_mirror(_ai_message_id, 0), do: :ok

  defp untrusted_tool_output(text) do
    nonce = "test-nonce"

    """
    <ankole_untrusted_tool_output nonce="#{nonce}">
    #{text}
    </ankole_untrusted_tool_output nonce="#{nonce}">
    """
    |> String.trim()
  end
end
