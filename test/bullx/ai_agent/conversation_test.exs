defmodule BullX.AIAgent.ConversationTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{Conversation, Conversations, Message}
  alias BullX.Principals

  test "conversation and message changesets enforce AIAgent storage invariants" do
    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-conversation-test",
        display_name: "Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Handle conversation storage tests."
          }
        }
      })

    assert {:ok, conversation} =
             Conversations.find_or_create_active(agent.uid, "v1:test", %{
               "conversation_key_parts" => %{"lane" => "addressed"}
             })

    assert %Conversation{} = conversation

    assert {:ok, updated, message} =
             Conversations.append_message(conversation, %{
               role: :user,
               kind: :normal,
               status: :complete,
               content: [Message.text_block("hello")],
               metadata: %{}
             })

    assert updated.id == conversation.id
    assert message.agent_uid == agent.uid
    assert message.conversation_id == conversation.id
    assert [%Message{id: message_id}] = Conversations.active_transcript(conversation)
    assert message_id == message.id

    changeset =
      Message.changeset(%Message{}, %{
        conversation_id: conversation.id,
        agent_uid: agent.uid,
        role: :tool,
        kind: :error,
        status: :complete,
        content: [Message.error_block("bad", "bad", false)],
        metadata: %{}
      })

    refute changeset.valid?
    assert %{role: [_ | _]} = errors_on(changeset)
  end

  test "inbound messages dedupe by conversation event identity" do
    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-dedupe-test",
        display_name: "Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Handle conversation dedupe tests."
          }
        }
      })

    {:ok, conversation} = Conversations.find_or_create_active(agent.uid, "v1:dedupe", %{})

    attrs = %{
      role: :user,
      kind: :normal,
      status: :complete,
      content: [Message.text_block("hello")],
      event_source: "bullx://test/conversation",
      event_id: "evt-dedupe-1",
      metadata: %{}
    }

    assert {:ok, _conversation, first} =
             Conversations.append_inbound_once(conversation, attrs)

    assert {:ok, _conversation, second} =
             Conversations.append_inbound_once(conversation, attrs)

    assert first.id == second.id
  end
end
