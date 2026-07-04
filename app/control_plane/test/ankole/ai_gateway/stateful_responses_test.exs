defmodule Ankole.AIGateway.StatefulResponsesTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.StatefulResponses

  describe "start_response_run/1" do
    test "creates a generating message row with metadata.actor_event_id" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-1")

      {:ok, message} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-123"
        })

      assert message.status == "generating"
      assert message.type == "message"
      assert message.metadata["actor_event_id"] == "event-123"
      assert is_nil(message.previous_message_id)
      assert message.content_version == 0
    end

    test "decodes previous_response_id to previous_message_id" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-2")

      # First: create an initial message and mark it complete.
      {:ok, first} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-a"
        })

      {:ok, first_complete} = StatefulResponses.commit_complete(first, [%{"type" => "message"}])

      # Now start a second run referencing the first as previous_response_id.
      {:ok, second} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-b",
          previous_response_id: "resp_#{first_complete.id}"
        })

      assert second.previous_message_id == first_complete.id
    end

    test "rejects non-complete anchor instead of silently rebasing" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-3")

      # Create a generating (not complete) message.
      {:ok, incomplete} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-c"
        })

      assert {:error, :invalid_anchor} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: "event-d",
                 previous_response_id: "resp_#{incomplete.id}"
               })
    end

    test "rejects malformed previous_response_id instead of raising" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-malformed-anchor")

      assert {:error, :invalid_anchor} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: "event-malformed-anchor",
                 previous_response_id: "resp_not-a-uuid"
               })
    end

    test "rejects a conversation owned by another agent" do
      owner = agent_fixture()
      caller = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(owner.principal.uid, "test-conv-cross-agent")

      assert {:error, :invalid_conversation} =
               StatefulResponses.start_response_run(%{
                 agent_uid: caller.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: "event-cross-agent"
               })
    end
  end

  describe "commit_complete/3" do
    test "flips status to complete and appends terminal items to request content" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-4")

      request_items = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Ping"}]
        }
      ]

      {:ok, message} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-e",
          request_items: request_items
        })

      output_items = [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hello"}]}
      ]

      {:ok, committed} =
        StatefulResponses.commit_complete(message, output_items, %{"usage" => %{}})

      assert committed.status == "complete"
      assert committed.content == request_items ++ output_items
      assert committed.content_version == 1
      assert committed.metadata["usage"] == %{}
    end

    test "returns already_terminal when another terminal transition won first" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-terminal-race")

      {:ok, message} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-terminal-race"
        })

      assert {:ok, _failed} = StatefulResponses.commit_error(message, [], %{"reason" => "closed"})
      assert {:ok, :already_terminal} = StatefulResponses.commit_complete(message, [])
    end
  end

  describe "commit_error/3" do
    test "flips status to error and preserves request content with partial output" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-5")

      request_items = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Ping"}]
        }
      ]

      {:ok, message} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-f",
          request_items: request_items
        })

      error = %{"code" => "rate_limit", "message" => "Too many requests"}

      partial_output = [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hel"}]}
      ]

      {:ok, failed} = StatefulResponses.commit_error(message, partial_output, error)

      assert failed.status == "error"
      assert failed.content == request_items ++ partial_output
      assert failed.metadata["error"]["code"] == "rate_limit"
    end
  end

  describe "expand_history/2" do
    test "returns complete message chain in chronological order" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-6")

      # Build a 3-message chain.
      {:ok, m1} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-g"
        })

      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "first"}])

      {:ok, m2} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-h",
          previous_response_id: "resp_#{m1.id}"
        })

      {:ok, m2} = StatefulResponses.commit_complete(m2, [%{"text" => "second"}])

      {:ok, m3} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-i",
          previous_response_id: "resp_#{m2.id}"
        })

      {:ok, m3} = StatefulResponses.commit_complete(m3, [%{"text" => "third"}])

      history = StatefulResponses.expand_history(conversation.id)

      assert length(history) == 3
      # Chronological order: oldest first.
      assert hd(history).id == m1.id
      assert List.last(history).id == m3.id
    end

    test "excludes generating rows by default" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-7")

      {:ok, m1} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-j"
        })

      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "done"}])

      # Start a second run but don't commit it.
      {:ok, _m2} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-k",
          previous_response_id: "resp_#{m1.id}"
        })

      history = StatefulResponses.expand_history(conversation.id)

      # Only the complete row should appear.
      assert length(history) == 1
    end

    test "returns an empty history for malformed previous_response_id instead of raising" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-bad-history-anchor")

      assert [] =
               StatefulResponses.expand_history(conversation.id,
                 previous_message_id: "resp_not-a-uuid"
               )
    end
  end

  describe "latest_visible_leaf/1" do
    test "returns the latest complete leaf message" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-8")

      {:ok, m1} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-l"
        })

      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "first"}])

      {:ok, m2} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: "event-m",
          previous_response_id: "resp_#{m1.id}"
        })

      {:ok, m2} = StatefulResponses.commit_complete(m2, [%{"text" => "second"}])

      leaf = StatefulResponses.latest_visible_leaf(conversation.id)
      assert leaf == m2.id
    end

    test "returns nil for empty conversation" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-9")

      assert StatefulResponses.latest_visible_leaf(conversation.id) == nil
    end
  end

  # Helpers — agent_fixture is imported from PrincipalsFixtures.
end
