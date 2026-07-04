defmodule Ankole.SignalsGatewayAIReplyPreviewTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Actors.ActorEvent
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockSignalProviderOutbox
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.SignalEntry

  setup :use_mock_signal_provider_plugin

  test "completed stateful response is delivered and mirrored as the final IM reply" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: actor_event} =
      emit_addressed_actor_event(
        agent.uid,
        "mock",
        group_entry(%{
          source_event_id: "preview-final-event",
          signal_channel_id: "mock:chat:preview-final",
          source_entry_id: "human-message-1",
          provider_thread_id: "mock-thread-1",
          explicit: true,
          text: "ping"
        })
      )

    assert :ok = AIReplyPreview.maybe_start_for(actor_event)

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    {:ok, message} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: [
          %{"role" => "user", "content" => "ping"}
        ]
      })

    output_items = [
      %{
        "type" => "message",
        "content" => [%{"type" => "output_text", "text" => "final answer"}]
      }
    ]

    assert {:ok, committed} = StatefulResponses.commit_complete(message, output_items)

    mirror = wait_for_final_mirror(committed.id)

    assert mirror.signal_channel_id == actor_event.signal_channel_id
    assert mirror.text == "final answer"
    assert mirror.source_entry_id =~ "mock-reply-"
    assert mirror.ai_message_id == committed.id
    assert mirror.metadata["actor_event_id"] == actor_event.id
    assert mirror.metadata["source"] == "ai_gateway_final_reply"
    assert mirror.metadata["provider_thread_id"] == actor_event.provider_thread_id
    assert String.starts_with?(mirror.document_id, "signal-entry:")
    refute mirror.document_id == mirror.source_entry_id
    assert mirror.metadata_text =~ "ai_gateway_final_reply"
    assert mirror.content_hash && mirror.content_hash != ""
  end

  test "function call round waits for final response before mirroring IM reply" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: actor_event} =
      emit_addressed_actor_event(
        agent.uid,
        "mock",
        group_entry(%{
          source_event_id: "preview-tool-loop-event",
          signal_channel_id: "mock:chat:preview-tool-loop",
          source_entry_id: "human-message-tool-loop",
          provider_thread_id: "mock-thread-tool-loop",
          explicit: true,
          text: "what is the weather?"
        })
      )

    assert :ok = AIReplyPreview.maybe_start_for(actor_event)

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    {:ok, first_round} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "what is the weather?"}]
          }
        ]
      })

    function_call_item = %{
      "type" => "function_call",
      "call_id" => "call_weather",
      "name" => "lookup_weather",
      "arguments" => ~s({"city":"Shanghai"})
    }

    assert {:ok, first_committed} =
             StatefulResponses.commit_complete(first_round, [function_call_item])

    refute_final_mirror(first_committed.id)

    {:ok, second_round} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        actor_event_id: actor_event.id,
        previous_response_id: "resp_#{first_committed.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_weather",
            "output" => "sunny"
          }
        ]
      })

    final_output_items = [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [
          %{"type" => "output_text", "text" => "It is sunny in Shanghai."}
        ]
      }
    ]

    assert {:ok, second_committed} =
             StatefulResponses.commit_complete(second_round, final_output_items)

    mirror = wait_for_final_mirror(second_committed.id)

    assert mirror.signal_channel_id == actor_event.signal_channel_id
    assert mirror.text == "It is sunny in Shanghai."
    assert mirror.source_entry_id =~ "mock-reply-"
    assert mirror.ai_message_id == second_committed.id
    assert mirror.metadata["actor_event_id"] == actor_event.id
    refute Repo.get_by(SignalEntry, ai_message_id: first_committed.id)
  end

  test "function call round does not reuse prior round preview text for an empty final response" do
    MockSignalProviderOutbox.put_recipient(self())
    on_exit(fn -> MockSignalProviderOutbox.delete_recipient() end)

    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: actor_event} =
      emit_addressed_actor_event(
        agent.uid,
        "mock",
        group_entry(%{
          source_event_id: "preview-tool-empty-final-event",
          signal_channel_id: "mock:chat:preview-tool-empty-final",
          source_entry_id: "human-message-tool-empty-final",
          provider_thread_id: "mock-thread-tool-empty-final",
          explicit: true,
          text: "run a tool"
        })
      )

    assert :ok = AIReplyPreview.maybe_start_for(actor_event)
    [{pid, _value}] = Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id)

    send(pid, {:ai_gateway_live, :response_started, %{}})
    send(pid, {:ai_gateway_live, :output_text_delta, %{text: "checking the tool"}})

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "checking the tool"

    first_message_id = Ecto.UUID.generate()

    send(
      pid,
      {:ai_gateway_event, :response_completed, first_message_id,
       %{
         content: [
           %{
             "type" => "function_call",
             "call_id" => "call_empty_final",
             "name" => "lookup",
             "arguments" => "{}"
           }
         ]
       }}
    )

    refute Repo.get_by(SignalEntry, ai_message_id: first_message_id)

    send(pid, {:ai_gateway_live, :response_started, %{}})

    final_message_id = Ecto.UUID.generate()

    send(
      pid,
      {:ai_gateway_event, :response_completed, final_message_id,
       %{
         content: [
           %{
             "type" => "message",
             "role" => "assistant",
             "content" => []
           }
         ]
       }}
    )

    assert_receive {:mock_provider_outbox_sent, final_edit}
    assert final_edit.operation == :edit
    assert final_edit.fallback_visible_text == ""
    refute final_edit.fallback_visible_text == initial.fallback_visible_text
    refute Repo.get_by(SignalEntry, ai_message_id: final_message_id)
  end

  test "preview edits and final edit use distinct idempotency keys" do
    MockSignalProviderOutbox.put_recipient(self())
    on_exit(fn -> MockSignalProviderOutbox.delete_recipient() end)

    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: actor_event} =
      emit_addressed_actor_event(
        agent.uid,
        "mock",
        group_entry(%{
          source_event_id: "preview-idempotency-event",
          signal_channel_id: "mock:chat:preview-idempotency",
          source_entry_id: "human-message-idempotency",
          provider_thread_id: "mock-thread-idempotency",
          explicit: true,
          text: "ping"
        })
      )

    assert :ok = AIReplyPreview.maybe_start_for(actor_event)
    [{pid, _value}] = Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id)

    send(pid, {:ai_gateway_live, :output_text_delta, %{text: "draft"}})

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.idempotency_key == "ai-preview:#{actor_event.id}:initial"

    preview_entry_id = initial.idempotency_key |> String.replace_prefix("ai-preview:", "")
    assert initial.operation == :reply

    send(pid, {:ai_gateway_live, :output_text_delta, %{text: " update"}})
    send(pid, :flush_edit)

    assert_receive {:mock_provider_outbox_sent, flush_edit}
    assert flush_edit.operation == :edit
    assert flush_edit.idempotency_key =~ ":flush:1"
    refute flush_edit.idempotency_key == initial.idempotency_key
    assert flush_edit.outbound_key == flush_edit.idempotency_key

    message_id = Ecto.UUID.generate()

    send(
      pid,
      {:ai_gateway_event, :response_completed, message_id,
       %{
         content: [
           %{
             "type" => "message",
             "role" => "assistant",
             "content" => [%{"type" => "output_text", "text" => "final answer"}]
           }
         ]
       }}
    )

    assert_receive {:mock_provider_outbox_sent, final_edit}
    assert final_edit.operation == :edit
    assert final_edit.idempotency_key =~ ":final:#{message_id}"
    refute final_edit.idempotency_key == flush_edit.idempotency_key
    assert final_edit.outbound_key == final_edit.idempotency_key
    assert final_edit.target_source_entry_id == flush_edit.target_source_entry_id
    refute is_nil(preview_entry_id)

    assert %SignalEntry{text: "final answer"} = wait_for_final_mirror(message_id)
  end

  test "live response activity resets the preview lifetime timer" do
    MockSignalProviderOutbox.put_recipient(self())
    on_exit(fn -> MockSignalProviderOutbox.delete_recipient() end)

    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: actor_event} =
      emit_addressed_actor_event(
        agent.uid,
        "mock",
        group_entry(%{
          source_event_id: "preview-lifetime-event",
          signal_channel_id: "mock:chat:preview-lifetime",
          source_entry_id: "human-message-lifetime",
          provider_thread_id: "mock-thread-lifetime",
          explicit: true,
          text: "ping"
        })
      )

    assert :ok = AIReplyPreview.maybe_start_for(actor_event)
    [{pid, _value}] = Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id)

    initial_ref = :sys.get_state(pid).lifetime_ref

    send(pid, {:ai_gateway_live, :response_started, %{}})
    started_ref = :sys.get_state(pid).lifetime_ref
    refute started_ref == initial_ref

    send(pid, {:lifetime_expired, initial_ref})
    assert Process.alive?(pid)

    send(pid, {:ai_gateway_live, :output_text_delta, %{text: "draft"}})
    delta_ref = :sys.get_state(pid).lifetime_ref
    refute delta_ref == started_ref

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply

    send(pid, {:lifetime_expired, started_ref})
    assert Process.alive?(pid)

    monitor = Process.monitor(pid)
    send(pid, {:lifetime_expired, delta_ref})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "silent-success marker for scheduled turns is not previewed or mirrored" do
    MockSignalProviderOutbox.put_recipient(self())
    on_exit(fn -> MockSignalProviderOutbox.delete_recipient() end)

    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")
    actor_event = scheduled_actor_event_fixture(agent.uid)

    assert :ok = AIReplyPreview.maybe_start_for(actor_event)
    [{pid, _value}] = Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id)

    send(pid, {:ai_gateway_live, :output_text_delta, %{text: "<silent_"}})
    send(pid, {:ai_gateway_live, :output_text_delta, %{text: "success/>"}})
    refute_receive {:mock_provider_outbox_sent, _outbox}, 100

    message_id = Ecto.UUID.generate()

    send(
      pid,
      {:ai_gateway_event, :response_completed, message_id,
       %{
         content: [
           %{
             "type" => "message",
             "role" => "assistant",
             "content" => [%{"type" => "output_text", "text" => "<silent_success/>"}]
           }
         ]
       }}
    )

    refute_receive {:mock_provider_outbox_sent, _outbox}, 100
    refute Repo.get_by(SignalEntry, ai_message_id: message_id)
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

  defp wait_for_final_mirror(ai_message_id, attempts_left \\ 20)

  defp wait_for_final_mirror(ai_message_id, attempts_left) when attempts_left > 0 do
    case Repo.get_by(SignalEntry, ai_message_id: ai_message_id) do
      %SignalEntry{} = entry ->
        entry

      nil ->
        receive do
        after
          50 -> wait_for_final_mirror(ai_message_id, attempts_left - 1)
        end
    end
  end

  defp wait_for_final_mirror(ai_message_id, 0) do
    flunk("expected final reply mirror for ai_message_id=#{ai_message_id}")
  end

  defp refute_final_mirror(ai_message_id, attempts_left \\ 3)

  defp refute_final_mirror(ai_message_id, attempts_left) when attempts_left > 0 do
    refute Repo.get_by(SignalEntry, ai_message_id: ai_message_id)

    receive do
    after
      20 -> refute_final_mirror(ai_message_id, attempts_left - 1)
    end
  end

  defp refute_final_mirror(_ai_message_id, 0), do: :ok

  defp scheduled_actor_event_fixture(agent_uid, opts \\ []) do
    now = DateTime.utc_now(:microsecond)

    attrs =
      %{
        agent_uid: agent_uid,
        binding_name: "mock",
        session_id: "mock:chat:schedule-silent",
        source_event_id: "schedule-silent-#{System.unique_integer([:positive])}",
        signal_channel_id: "mock:chat:schedule-silent",
        provider_thread_id: "mock-thread-schedule-silent",
        source_entry_id: "schedule-source-entry",
        type: "check_back_later.wakeup",
        available_at: now,
        queue_sequence: System.unique_integer([:positive]),
        input_state: "open",
        payload: %{"data" => %{"wake_payload" => %{}}}
      }
      |> Map.merge(Map.new(opts))

    %ActorEvent{}
    |> ActorEvent.changeset(attrs)
    |> Repo.insert!()
  end
end
