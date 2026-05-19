defmodule BullX.AIAgent.CommandsTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{ACL, Commands, Conversation, Conversations, Message, Profile}
  alias BullX.AuthZ
  alias BullX.Principals

  test "detect_text recognizes the command catalog and aliases" do
    assert {:command, "new", ""} = Commands.detect_text("/new")
    assert {:command, "new", ""} = Commands.detect_text("/新会话")

    assert {:command, "steer", "focus on the latest incident"} =
             Commands.detect_text("  /steer focus on the latest incident")

    assert {:unknown, "/unknown"} = Commands.detect_text("/unknown arg")
    assert :not_command = Commands.detect_text("ordinary message")
  end

  test "retry supersedes generated suffix and acquires replacement lease" do
    %{agent: agent, caller: caller, profile: profile} = setup_command_subjects("retry")
    {:ok, conversation} = Conversations.find_or_create_active(agent.id, "v1:commands-retry", %{})
    {:ok, conversation, user} = append_user(conversation, "search again")
    {:ok, _conversation, assistant} = append_assistant(conversation, user, "old answer")

    entry_id = BullX.Ext.gen_uuid_v7()

    assert {:ok,
            %{
              status: :start_generation,
              source_message_id: user_id,
              retry_of_message_id: assistant_id,
              lease_id: lease_id
            }} =
             Commands.run(
               "retry",
               command_context(conversation, caller, agent, profile, entry_id)
             )

    assert user_id == user.id
    assert assistant_id == assistant.id
    assert is_binary(lease_id)

    assert %Conversation{
             current_leaf_message_id: ^user_id,
             generation: %{"lease_id" => ^lease_id}
           } =
             Repo.get!(Conversation, conversation.id)

    assert %Message{metadata: %{"branch_effect" => %{"state" => "superseded"}}} =
             Repo.get!(Message, assistant.id)
  end

  test "undo marks the latest exchange as undone and rewinds the leaf" do
    %{agent: agent, caller: caller, profile: profile} = setup_command_subjects("undo")
    {:ok, conversation} = Conversations.find_or_create_active(agent.id, "v1:commands-undo", %{})
    {:ok, conversation, user} = append_user(conversation, "remove this")
    {:ok, _conversation, assistant} = append_assistant(conversation, user, "draft answer")

    entry_id = BullX.Ext.gen_uuid_v7()

    assert {:ok, %{status: :ok, command: "undo"}} =
             Commands.run("undo", command_context(conversation, caller, agent, profile, entry_id))

    assert %Conversation{current_leaf_message_id: nil} = Repo.get!(Conversation, conversation.id)

    assert %Message{metadata: %{"branch_effect" => %{"state" => "undone"}}} =
             Repo.get!(Message, user.id)

    assert %Message{metadata: %{"branch_effect" => %{"state" => "undone"}}} =
             Repo.get!(Message, assistant.id)
  end

  defp setup_command_subjects(suffix) do
    {:ok, %{principal: caller}} =
      Principals.create_human(%{
        uid: "ai-agent-command-caller-#{suffix}",
        display_name: "Caller #{suffix}"
      })

    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-command-agent-#{suffix}",
        display_name: "Agent #{suffix}",
        profile: %{"ai_agent" => %{"main_model" => "openai_proxy:gpt-test"}}
      })

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_id: caller.id,
        resource_pattern: ACL.resource(agent.id),
        action: "invoke"
      })

    {:ok, profile} =
      Profile.cast(%{
        "ai_agent" => %{
          "main_model" => "openai_proxy:gpt-test",
          "context" => %{"max_turns" => 3}
        }
      })

    %{agent: agent, caller: caller, profile: profile}
  end

  defp append_user(conversation, text) do
    Conversations.append_message(conversation, %{
      conversation_id: conversation.id,
      role: :user,
      kind: :normal,
      status: :complete,
      content: [Message.text_block(text)],
      metadata: %{}
    })
  end

  defp append_assistant(conversation, source, text) do
    Conversations.append_message(conversation, %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :normal,
      status: :complete,
      content: [Message.text_block(text)],
      metadata: %{
        "generation" => %{
          "source_message_id" => source.id,
          "source_type" => "target_session_entry",
          "source_id" => BullX.Ext.gen_uuid_v7()
        }
      }
    })
  end

  defp command_context(conversation, caller, agent, profile, entry_id) do
    %{
      args: "",
      conversation_id: conversation.id,
      caller_principal_id: caller.id,
      agent_principal_id: agent.id,
      profile: profile,
      source_type: "target_session_entry",
      source_id: entry_id,
      target_session_id: BullX.Ext.gen_uuid_v7(),
      target_session_entry_id: entry_id,
      acl_context: %{}
    }
  end
end
