defmodule BullX.AIAgent.PromptRendererTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{Conversations, Message, Profile, PromptRenderer}
  alias BullX.Principals

  test "renders every tool result for a multi-tool assistant turn" do
    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-prompt-renderer-tools",
        display_name: "Agent",
        profile: %{"ai_agent" => %{"main_model" => "openai_proxy:gpt-test"}}
      })

    {:ok, profile} =
      Profile.cast(%{"ai_agent" => %{"main_model" => "openai_proxy:gpt-test"}})

    {:ok, conversation} = Conversations.find_or_create_active(agent.id, "v1:tools", %{})

    {:ok, conversation, _user} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :user,
        kind: :normal,
        status: :complete,
        content: [Message.text_block("search and fetch")],
        metadata: %{}
      })

    {:ok, conversation, _assistant} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :assistant,
        kind: :normal,
        status: :complete,
        content: [
          %{
            "type" => "tool_call",
            "tool_call_id" => "call_1",
            "name" => "first",
            "arguments" => %{}
          },
          %{
            "type" => "tool_call",
            "tool_call_id" => "call_2",
            "name" => "second",
            "arguments" => %{}
          }
        ],
        metadata: %{}
      })

    {:ok, conversation, _tool} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :tool,
        kind: :normal,
        status: :complete,
        content: [
          %{
            "type" => "tool_result",
            "tool_call_id" => "call_1",
            "is_error" => false,
            "result" => %{"ok" => 1}
          },
          %{
            "type" => "tool_result",
            "tool_call_id" => "call_2",
            "is_error" => false,
            "result" => %{"ok" => 2}
          }
        ],
        metadata: %{}
      })

    {:ok, conversation, source} =
      Conversations.append_message(conversation, %{
        conversation_id: conversation.id,
        role: :user,
        kind: :normal,
        status: :complete,
        content: [Message.text_block("continue")],
        metadata: %{}
      })

    assert {:ok, rendered} = PromptRenderer.render(conversation, profile, source)

    assert ["call_1", "call_2"] =
             rendered.messages
             |> Enum.filter(&(&1.role == :tool))
             |> Enum.map(& &1.tool_call_id)
  end
end
