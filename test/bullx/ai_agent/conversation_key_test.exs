defmodule BullX.AIAgent.ConversationKeyTest do
  use BullX.DataCase, async: true

  alias BullX.AIAgent.{ConversationKey, Profile}

  test "builds deterministic length-prefixed scene key" do
    {:ok, profile} =
      Profile.cast(%{
        "ai_agent" => %{
          "main_model" => "openai_proxy:gpt-test",
          "conversation_isolation_mode" => "scene"
        }
      })

    data = %{
      "channel" => %{"adapter" => "feishu", "id" => "chat-1", "kind" => "group"},
      "scope" => %{"id" => "scene-1", "thread_id" => "thread-1"},
      "actor" => %{"external_account_id" => "ou_1"}
    }

    assert {:ok, key, metadata} =
             ConversationKey.build(profile, "018f-agent", :addressed, data)

    expected_serialized =
      [
        "ai_agent_conversation:v1",
        "9:addressed",
        "10:018f-agent",
        "6:feishu",
        "6:chat-1",
        "5:group",
        "7:scene-1",
        "8:thread-1",
        "5:scene",
        "0:"
      ]
      |> IO.iodata_to_binary()

    assert key == "v1:" <> BullX.Ext.generic_hash(expected_serialized)
    assert metadata["conversation_key_parts"]["lane"] == "addressed"
    assert metadata["conversation_key_parts"]["actor_external_account_id_present"] == false
  end

  test "actor isolation requires normalized external actor id" do
    {:ok, profile} =
      Profile.cast(%{
        "ai_agent" => %{
          "main_model" => "openai_proxy:gpt-test",
          "conversation_isolation_mode" => "actor"
        }
      })

    data = %{
      "channel" => %{"adapter" => "feishu", "id" => "chat-1", "kind" => "group"},
      "scope" => %{"id" => "scene-1"}
    }

    assert {:error, :missing_conversation_key_parts} =
             ConversationKey.build(profile, "018f-agent", :addressed, data)
  end

  test "rejects NUL-containing normalized key parts" do
    {:ok, profile} = Profile.cast(%{"ai_agent" => %{"main_model" => "openai_proxy:gpt-test"}})

    data = %{
      "channel" => %{"adapter" => "feishu", "id" => "chat" <> <<0>>, "kind" => "group"},
      "scope" => %{"id" => "scene-1"}
    }

    assert {:error, :conversation_key_part_contains_nul} =
             ConversationKey.build(profile, "018f-agent", :ambient, data)
  end
end
