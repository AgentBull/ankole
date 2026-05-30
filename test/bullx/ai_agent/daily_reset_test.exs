defmodule BullX.AIAgent.DailyResetTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{Conversation, Conversations, DailyReset, Message, Profile}
  alias BullX.Principals

  test "close_eligible uses one complete-message activity projection for active conversations" do
    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "daily-reset-agent",
        display_name: "Daily Reset Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Test daily reset."
          }
        }
      })

    now = ~U[2026-05-31 12:00:00.000000Z]
    old = ~U[2026-05-30 01:00:00.000000Z]
    recent = ~U[2026-05-31 11:00:00.000000Z]

    {:ok, profile} =
      Profile.cast(%{
        "ai_agent" => %{
          "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
          "mission" => "Test daily reset.",
          "daily_reset" => %{
            "enabled" => true,
            "hour" => "04:00",
            "timezone" => "Etc/UTC",
            "retry_minutes" => 30
          }
        }
      })

    stale = conversation_with_activity!(agent.uid, "v1:stale", old, old)
    recent_message = conversation_with_activity!(agent.uid, "v1:recent-message", old, recent)
    empty = conversation_without_messages!(agent.uid, "v1:empty", old)

    assert {:ok, 2} = DailyReset.close_eligible(profile, now, agent.uid)

    assert Repo.get!(Conversation, stale.id).ended_at == now
    assert is_nil(Repo.get!(Conversation, recent_message.id).ended_at)
    assert Repo.get!(Conversation, empty.id).ended_at == now
  end

  defp conversation_with_activity!(agent_uid, key, conversation_updated_at, message_updated_at) do
    conversation = conversation_without_messages!(agent_uid, key, conversation_updated_at)

    {:ok, _conversation, message} =
      Conversations.append_message(conversation, %{
        role: :user,
        kind: :normal,
        status: :complete,
        content: [Message.text_block(key)],
        metadata: %{}
      })

    shift_message!(message.id, message_updated_at)

    conversation
  end

  defp conversation_without_messages!(agent_uid, key, updated_at) do
    {:ok, conversation} = Conversations.find_or_create_active(agent_uid, key, %{})

    Repo.update_all(
      from(c in Conversation, where: c.id == ^conversation.id),
      set: [inserted_at: updated_at, updated_at: updated_at]
    )

    Repo.get!(Conversation, conversation.id)
  end

  defp shift_message!(message_id, updated_at) do
    Repo.update_all(
      from(m in Message, where: m.id == ^message_id),
      set: [inserted_at: updated_at, updated_at: updated_at]
    )
  end
end
