defmodule Ankole.Sessions.AIGatewayMainChainTest do
  alias Ankole.AIGateway.ToolResultJournal
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SessionsCase

  import Ankole.FilesFixtures, only: [sent_attachment_fixture: 4]

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Presentation
  alias Ankole.Sessions.Run
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec

  setup :use_mock_signal_provider_plugin

  test "IM input stays open through Responses rounds and closes with the terminal decision" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsFixtures.binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: signal, run: run, preview_handler: preview_handler} =
      admit_event(agent.uid, %{
        source_event_id: "main-chain-event",
        provider_conversation_id: "mock:chat:main-chain",
        provider_message_id: "human-main-chain-1",
        provider_thread_id: "mock-thread-main-chain",
        explicit: true,
        text: "Need the weather."
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, signal.session_id)

    first_request_items = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "Need the weather."}]
      }
    ]

    {:ok, first_round} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: signal_metadata(signal.id),
        request_items: first_request_items
      })

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_weather",
      "name" => "lookup_weather",
      "arguments" => ~s({"city":"Shanghai"})
    }

    assert {:ok, first_committed} =
             ResponseCommit.commit_complete(first_round, [function_call])

    assert first_committed.previous_message_id == nil
    assert first_committed.content == first_request_items ++ [function_call]
    assert is_nil(Repo.get!(Signal, signal.id).completed_at)
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
      start_response_run(%{
        subject_uid: agent.uid,
        metadata: signal_metadata(signal.id),
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

    assert {:ok, final_committed} = ResponseCommit.commit_complete(second_round, final_output)

    assert final_committed.content == tool_result_items ++ final_output
    assert is_nil(Repo.get!(Signal, signal.id).completed_at)
    assert Process.alive?(preview_handler)
    refute Repo.get_by(Intent, source_signal_id: signal.id)

    assert {:ok, %{status: :completed}} =
             finalize_run(run, final_committed)

    assert %DateTime{} = Repo.get!(Signal, signal.id).completed_at
    refute Process.alive?(preview_handler)

    dispatch_final_reply_intent!(final_committed.id)
    mirror = wait_for_final_mirror(final_committed.id)
    assert mirror.message.conversation_id == signal.conversation_id
    assert mirror.message.text == "It is sunny in Shanghai."
    assert mirror.external_ref.ai_message_id == final_committed.id
    assert mirror.external_ref.metadata["signal_id"] == signal.id
    refute Repo.get_by(ExternalMessageRef, ai_message_id: first_committed.id)
  end

  test "reply_attachment tool output commits a durable intent row on final response" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsFixtures.binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: signal, run: run} =
      admit_event(agent.uid, %{
        source_event_id: "reply-attachment-main-chain-event",
        provider_conversation_id: "mock:chat:reply-attachment",
        provider_message_id: "human-reply-attachment-1",
        provider_thread_id: "mock-thread-reply-attachment",
        explicit: true,
        text: "Attach the report."
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, signal.session_id)

    {:ok, first_round} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: signal_metadata(signal.id),
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "Attach the report."
          }
        ]
      })

    assert {:ok, first_committed} =
             ResponseCommit.commit_complete(first_round, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_reply_attachment",
                 "name" => "reply_attachment",
                 "arguments" =>
                   ~s({"path":"reports/chaos-report.txt","name":"chaos-report.txt","mimeType":"text/plain"})
               }
             ])

    attachment =
      sent_attachment_fixture(
        agent.uid,
        "chaos-report.txt",
        "CHAOS_REPLY_ATTACHMENT_BODY",
        "text/plain"
      )

    {:ok, second_round} =
      start_response_run(%{
        subject_uid: agent.uid,
        metadata: signal_metadata(signal.id),
        previous_response_id: "resp_#{first_committed.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_reply_attachment",
            "output" =>
              Ankole.JSON.encode!(%{
                "tool" => "reply_attachment",
                "ok" => true,
                "attachments" => [attachment]
              })
          }
        ]
      })

    assert {:ok, final_committed} =
             ResponseCommit.commit_complete(second_round, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "CHAOS_REPLY_ATTACHMENT_OK"}
                 ]
               }
             ])

    refute Repo.get_by(Intent, source_signal_id: signal.id)

    assert {:ok, %{status: :completed}} =
             finalize_run(run, final_committed)

    intent =
      Repo.get_by!(Intent,
        agent_uid: agent.uid,
        binding_name: "mock",
        outbound_key: "ai-reply-attachment:#{final_committed.id}:0"
      )

    assert intent.status == :pending
    assert intent.operation == :reply
    assert intent.source_signal_id == signal.id
    assert intent.ai_message_id == final_committed.id
    assert intent.reply_to_provider_message_id == "human-reply-attachment-1"
    assert intent.payload["attachments"] == [attachment]
    refute Map.has_key?(intent.payload, "text")
    assert is_nil(intent.fallback_visible_text)

    dispatch_attachment_intent!(final_committed.id)
    dispatch_final_reply_intent!(final_committed.id)

    %{attachment: attachment_mirror, final: final_mirror} =
      wait_for_attachment_and_final_mirrors(final_committed.id)

    assert is_nil(attachment_mirror.message.text)
    assert [mirrored_attachment] = attachment_mirror.message.attachments
    assert is_integer(mirrored_attachment["attachment_id"])
    assert Map.delete(mirrored_attachment, "attachment_id") == attachment
    assert final_mirror.message.text == "CHAOS_REPLY_ATTACHMENT_OK"
  end

  test "reply_attachment tool result journal commits attachment intent on final response" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsFixtures.binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: signal, run: run} =
      admit_event(agent.uid, %{
        source_event_id: "reply-attachment-journal-event",
        provider_conversation_id: "mock:chat:reply-attachment-journal",
        provider_message_id: "human-reply-attachment-journal-1",
        provider_thread_id: "mock-thread-reply-attachment-journal",
        explicit: true,
        text: "Create the chart and send it."
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, signal.session_id)

    {:ok, first_round} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: signal_metadata(signal.id),
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "Create the chart and send it."
          }
        ]
      })

    assert {:ok, first_committed} =
             ResponseCommit.commit_complete(first_round, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_reply_attachment_journal",
                 "name" => "reply_attachment",
                 "arguments" =>
                   ~s({"path":"charts/sales.png","name":"sales.png","mimeType":"image/png"})
               }
             ])

    attachment = sent_attachment_fixture(agent.uid, "sales.png", <<137, 80, 78, 71>>, "image/png")

    assert {:ok, journal} =
             record_tool_results(%{
               subject_uid: agent.uid,
               metadata: signal_metadata(signal.id),
               previous_response_id: "resp_#{first_committed.id}",
               request_items: [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_reply_attachment_journal",
                   "output" =>
                     Ankole.JSON.encode!(%{
                       "tool" => "reply_attachment",
                       "ok" => true,
                       "attachments" => [attachment]
                     })
                 }
               ]
             })

    assert journal.metadata["tool_result_journal"] == true

    {:ok, final_round} =
      start_response_run(%{
        subject_uid: agent.uid,
        metadata: signal_metadata(signal.id),
        previous_response_id: "resp_#{journal.id}",
        request_items: []
      })

    assert {:ok, final_committed} =
             ResponseCommit.commit_complete(final_round, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "SALES_CHART_ATTACHED"}
                 ]
               }
             ])

    refute Repo.get_by(Intent, source_signal_id: signal.id)

    assert {:ok, %{status: :completed}} =
             finalize_run(run, final_committed)

    intent =
      Repo.get_by!(Intent,
        agent_uid: agent.uid,
        binding_name: "mock",
        outbound_key: "ai-reply-attachment:#{final_committed.id}:0"
      )

    assert intent.status == :pending
    assert intent.operation == :reply
    assert intent.source_signal_id == signal.id
    assert intent.ai_message_id == final_committed.id
    assert intent.reply_to_provider_message_id == "human-reply-attachment-journal-1"
    assert intent.payload["attachments"] == [attachment]
    refute Map.has_key?(intent.payload, "text")
    assert is_nil(intent.fallback_visible_text)
    refute Repo.get_by(Intent, outbound_key: "ai-reply-attachment:#{journal.id}:0")

    dispatch_attachment_intent!(final_committed.id)
    dispatch_final_reply_intent!(final_committed.id)

    %{attachment: attachment_mirror, final: final_mirror} =
      wait_for_attachment_and_final_mirrors(final_committed.id)

    assert is_nil(attachment_mirror.message.text)
    assert [mirrored_attachment] = attachment_mirror.message.attachments
    assert is_integer(mirrored_attachment["attachment_id"])
    assert Map.delete(mirrored_attachment, "attachment_id") == attachment
    assert final_mirror.message.text == "SALES_CHART_ATTACHED"
  end

  test "clarify tool output replaces the plain final reply with one durable interactive intent" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsFixtures.binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: signal, run: run} =
      admit_event(agent.uid, %{
        source_event_id: "clarify-main-chain-event",
        provider_conversation_id: "mock:chat:clarify",
        provider_message_id: "human-clarify-1",
        provider_thread_id: "mock-thread-clarify",
        explicit: true,
        text: "Prepare the brief."
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, signal.session_id)

    {:ok, first_round} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: signal_metadata(signal.id),
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => "Prepare the brief."
          }
        ]
      })

    assert {:ok, first_committed} =
             ResponseCommit.commit_complete(first_round, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_clarify_audience",
                 "name" => "clarify",
                 "arguments" =>
                   ~s({"question":"Who should this brief target?","choices":[{"label":"Operators"},{"label":"Executives"}]})
               }
             ])

    {:ok, final_round} =
      start_response_run(%{
        subject_uid: agent.uid,
        metadata: signal_metadata(signal.id),
        previous_response_id: "resp_#{first_committed.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_clarify_audience",
            "output" =>
              Ankole.JSON.encode!(%{
                "tool" => "clarify",
                "ok" => true,
                "question" => "Who should this brief target?",
                "choices" => [
                  %{"label" => "Operators"},
                  %{"label" => "Executives"}
                ]
              })
          }
        ]
      })

    assert {:ok, final_committed} =
             ResponseCommit.commit_complete(final_round, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "output_text", "text" => "I need one decision first."}
                 ]
               }
             ])

    refute Repo.get_by(Intent, source_signal_id: signal.id)

    assert {:ok, %{status: :completed}} =
             finalize_run(run, final_committed)

    intent =
      Repo.get_by!(Intent,
        agent_uid: agent.uid,
        binding_name: "mock",
        outbound_key: "ai-reply:#{final_committed.id}"
      )

    assert intent.status == :pending
    assert intent.operation == :reply
    assert intent.source_signal_id == signal.id
    assert intent.ai_message_id == final_committed.id
    assert intent.reply_to_provider_message_id == "human-clarify-1"
    assert intent.payload["metadata"]["source"] == "ai_gateway_clarify"
    assert intent.payload["text"] =~ "I need one decision first."
    assert intent.payload["text"] =~ "Who should this brief target?"

    assert Enum.map(intent.payload["interactive_output"]["choices"], & &1["label"]) ==
             ["Operators", "Executives"]

    assert intent.payload["interactive_output"]["free_input"]

    assert Repo.aggregate(
             from(entry in Intent,
               where:
                 entry.ai_message_id == ^final_committed.id and
                   entry.outbound_key == ^intent.outbound_key
             ),
             :count
           ) == 1
  end

  defp admit_event(agent_uid, event_attrs) do
    %{signal: event} =
      Ankole.SignalsFixtures.emit_addressed_signal(
        agent_uid,
        "mock",
        Ankole.SignalsFixtures.group_entry(event_attrs)
      )

    refute preview_handler_started?(event.id)

    assert {:ok, run} =
             Admission.admit(%{agent_uid: agent_uid, session_id: event.session_id}, event)

    Presentation.start(run, self())
    %{signal: event, run: run, preview_handler: wait_for_preview_handler(event.id)}
  end

  defp finalize_run(run, final_response, outcome \\ :loop_finished) do
    Run.finalize(%{run | anchor: final_response.id}, outcome)
  end

  # StatefulResponses is an internal storage API. The caller-owned metadata
  # object remains opaque under the same request_metadata envelope used by the
  # public Responses lifecycle.
  defp signal_metadata(signal_id) do
    %{"request_metadata" => %{"signal_id" => signal_id}}
  end

  defp preview_handler_started?(signal_id) do
    Ankole.Conversations.Delivery.Preview.lookup(signal_id) != []
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp wait_for_preview_handler(signal_id, attempts_left \\ 20)

  defp wait_for_preview_handler(signal_id, attempts_left) when attempts_left > 0 do
    case Ankole.Conversations.Delivery.Preview.lookup(signal_id) do
      [{pid, _value}] ->
        pid

      [] ->
        Process.sleep(10)
        wait_for_preview_handler(signal_id, attempts_left - 1)
    end
  end

  defp wait_for_preview_handler(signal_id, 0) do
    flunk("preview handler for signal_id=#{signal_id} was not started")
  end

  defp dispatch_attachment_intent!(ai_message_id) do
    intent = Repo.get_by!(Intent, outbound_key: "ai-reply-attachment:#{ai_message_id}:0")

    assert {:ok, %Intent{status: :sent}} =
             Ankole.Conversations.Delivery.dispatch(
               intent.agent_uid,
               intent.binding_name,
               intent.outbound_key,
               delivery_adapter([:post_entry, :reply_entry, :edit_entry], fn _intent ->
                 {:ok,
                  %{
                    created_provider_message_id: "test-attachment-#{ai_message_id}",
                    raw_payload: %{"provider" => "test"}
                  }}
               end)
             )

    :ok
  end

  # The attachment message and the final reply mirror separately. Splitting them
  # by attachment proves the file row carries no copy of the answer text.
  defp wait_for_attachment_and_final_mirrors(ai_message_id, attempts_left \\ 20)

  defp wait_for_attachment_and_final_mirrors(ai_message_id, attempts_left)
       when attempts_left > 0 do
    case Repo.all(
           from(message in ConversationMessage,
             join: ref in ExternalMessageRef,
             on: ref.message_id == message.id,
             where: ref.ai_message_id == ^ai_message_id,
             select: %{message: message, external_ref: ref}
           )
         ) do
      entries when length(entries) == 2 ->
        {[attachment], [final]} = Enum.split_with(entries, &(&1.message.attachments != []))
        %{attachment: attachment, final: final}

      _entries ->
        Process.sleep(50)
        wait_for_attachment_and_final_mirrors(ai_message_id, attempts_left - 1)
    end
  end

  defp wait_for_attachment_and_final_mirrors(ai_message_id, 0) do
    flunk("expected attachment and final reply mirrors for ai_message_id=#{ai_message_id}")
  end

  defp refute_final_mirror(ai_message_id, attempts_left \\ 3)

  defp refute_final_mirror(ai_message_id, attempts_left) when attempts_left > 0 do
    refute Repo.get_by(ExternalMessageRef, ai_message_id: ai_message_id)
    Process.sleep(20)
    refute_final_mirror(ai_message_id, attempts_left - 1)
  end

  defp refute_final_mirror(_ai_message_id, 0), do: :ok

  defp record_tool_results(attrs) do
    {:ok, result} =
      Ankole.Repo.transact(fn ->
        {:ok, ToolResultJournal.record_tool_results_in_tx(attrs)}
      end)

    case result do
      {:ok, message, _disposition} ->
        ToolResultJournal.publish_tool_result_events(message)
        {:ok, message}

      error ->
        error
    end
  end
end
