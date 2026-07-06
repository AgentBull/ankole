defmodule Ankole.SignalsGateway.FinalReplyOutboxTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.OutboxEntry

  setup :use_mock_signal_provider_plugin

  describe "durable final reply outbox" do
    test "terminal commit without preview writes a durable reply outbox and mirrors after success" do
      %{message: message, event: event} = start_im_visible_response_run()
      content = assistant_content("final answer")

      assert {:ok, completed} = StatefulResponses.commit_complete(message, content)
      assert completed.status == "complete"

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      assert outbox.operation == :reply
      assert outbox.reply_to_source_entry_id == event.source_entry_id
      assert outbox.ai_message_id == message.id
      assert outbox.fallback_visible_text == "final answer"

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter(:reply_entry, "provider-final-reply")
               )

      assert %Entry{source_entry_id: "provider-final-reply", ai_message_id: ai_message_id} =
               Repo.get_by!(Entry, ai_message_id: message.id)

      assert ai_message_id == message.id
    end

    test "terminal commit with preview writes a durable edit outbox and upserts final marker" do
      %{message: message, event: event} = start_im_visible_response_run()
      assert :ok = StatefulResponses.record_preview_source_entry(event.id, "provider-preview")

      assert {:ok, _completed} =
               StatefulResponses.commit_complete(message, assistant_content("edited final"))

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      assert outbox.operation == :edit
      assert outbox.target_source_entry_id == "provider-preview"
      assert outbox.ai_message_id == message.id

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter(:edit_entry, "ignored-for-edit")
               )

      assert %Entry{
               source_entry_id: "provider-preview",
               ai_message_id: ai_message_id,
               text: "edited final"
             } = Repo.get_by!(Entry, ai_message_id: message.id)

      assert ai_message_id == message.id
    end
  end

  defp start_im_visible_response_run do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: event} =
      emit_addressed_actor_event(
        agent.uid,
        "mock",
        group_entry(%{
          explicit: true,
          source_event_id: "evt-#{System.unique_integer([:positive])}",
          source_entry_id: "msg-#{System.unique_integer([:positive])}"
        })
      )

    assert {:ok, conversation} =
             StatefulResponses.ensure_conversation(agent.uid, event.session_id)

    assert {:ok, message} =
             StatefulResponses.start_response_run(%{
               agent_uid: agent.uid,
               conversation_id: conversation.id,
               actor_event_id: event.id
             })

    %{agent: agent, event: event, message: message}
  end

  defp assistant_content(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp adapter(capability, created_source_entry_id) do
    %{
      capabilities: [capability],
      send: fn _outbox ->
        {:ok,
         %{
           created_source_entry_id: created_source_entry_id,
           raw_payload: %{"provider" => "test"}
         }}
      end
    }
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
end
