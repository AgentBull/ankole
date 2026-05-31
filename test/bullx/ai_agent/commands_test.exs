defmodule BullX.AIAgent.CommandsTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{ACL, Commands, Conversation, Conversations, Message, Profile}
  alias BullX.AuthZ
  alias BullX.Principals

  test "command events preserve gateway-normalized names and args" do
    data = %{
      "command" => %{
        "name" => "UNKNOWN",
        "args_text" => "focus on the latest incident"
      },
      "routing_facts" => %{"command_name" => "ignored"}
    }

    assert Commands.command_event_name(data) == "unknown"
    assert Commands.command_event_args(data) == "focus on the latest incident"
  end

  test "retry supersedes generated suffix and acquires replacement lease" do
    %{agent: agent, caller: caller, profile: profile} = setup_command_subjects("retry")
    {:ok, conversation} = Conversations.find_or_create_active(agent.uid, "v1:commands-retry", %{})
    {:ok, conversation, user} = append_user(conversation, "search again")
    {:ok, _conversation, assistant} = append_assistant(conversation, user, "old answer", "om_old")

    entry_id = BullX.Ext.gen_uuid_v7()

    assert {:ok,
            %{
              status: :start_generation,
              trigger_message_id: user_id,
              retry_of_message_id: assistant_id,
              lease_id: lease_id,
              recall_targets: [%{"message_id" => assistant_message_id, "external_id" => "om_old"}]
            }} =
             Commands.run(
               "retry",
               command_context(conversation, caller, agent, profile, entry_id)
             )

    assert user_id == user.id
    assert assistant_id == assistant.id
    assert assistant_message_id == assistant.id
    assert is_binary(lease_id)

    assert %Conversation{generation: %{"lease_id" => ^lease_id}} =
             Repo.get!(Conversation, conversation.id)

    assert %Message{metadata: %{"transcript_effect" => %{"state" => "superseded"}}} =
             Repo.get!(Message, assistant.id)
  end

  test "undo marks the latest exchange as undone" do
    %{agent: agent, caller: caller, profile: profile} = setup_command_subjects("undo")
    {:ok, conversation} = Conversations.find_or_create_active(agent.uid, "v1:commands-undo", %{})
    {:ok, conversation, user} = append_user(conversation, "remove this")

    {:ok, _conversation, assistant} =
      append_assistant(conversation, user, "draft answer", "om_undo")

    entry_id = BullX.Ext.gen_uuid_v7()

    assert {:ok,
            %{
              status: :ok,
              command: "undo",
              recall_targets: [
                %{"message_id" => assistant_message_id, "external_id" => "om_undo"}
              ]
            }} =
             Commands.run("undo", command_context(conversation, caller, agent, profile, entry_id))

    assert assistant_message_id == assistant.id

    assert %Message{metadata: %{"transcript_effect" => %{"state" => "undone"}}} =
             Repo.get!(Message, user.id)

    assert %Message{metadata: %{"transcript_effect" => %{"state" => "undone"}}} =
             Repo.get!(Message, assistant.id)
  end

  test "stop marks generating assistant output interrupted and recalls streamed delivery" do
    %{agent: agent, caller: caller, profile: profile} = setup_command_subjects("stop")
    {:ok, conversation} = Conversations.find_or_create_active(agent.uid, "v1:commands-stop", %{})
    {:ok, conversation, user} = append_user(conversation, "stream this")

    now = DateTime.utc_now(:microsecond)

    owner = %{
      "owner_trigger_type" => "mailbox_entry",
      "owner_trigger_id" => BullX.Ext.gen_uuid_v7(),
      "trigger_message_id" => user.id,
      "generation_lease_ttl_ms" => profile.generation.generation_lease_ttl_ms,
      "generation_heartbeat_interval_ms" => profile.generation.generation_heartbeat_interval_ms,
      "generation_max_runtime_ms" => profile.generation.generation_max_runtime_ms
    }

    {:ok, leased, lease_id} =
      Conversations.acquire_generation_lease_locked(conversation, owner, now)

    {:ok, _conversation, assistant} =
      Conversations.append_message(leased, %{
        conversation_id: leased.id,
        role: :assistant,
        kind: :normal,
        status: :generating,
        content: [],
        metadata: %{
          "generation" => %{"lease_id" => lease_id, "trigger_message_id" => user.id},
          "delivery" => delivery_metadata("om_stream"),
          "stream" => %{"stream_id" => "stream_1", "status" => "open"}
        }
      })

    entry_id = BullX.Ext.gen_uuid_v7()

    assert {:ok,
            %{
              status: :ok,
              command: "stop",
              recall_targets: [
                %{"message_id" => assistant_message_id, "external_id" => "om_stream"}
              ]
            }} =
             Commands.run("stop", command_context(leased, caller, agent, profile, entry_id))

    assert assistant_message_id == assistant.id

    assert %Message{
             kind: :error,
             status: :complete,
             metadata: %{
               "transcript_effect" => %{"state" => "interrupted"},
               "stream" => %{"status" => "interrupted"}
             }
           } = Repo.get!(Message, assistant.id)
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
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Handle command tests."
          }
        }
      })

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: caller.uid,
        resource_pattern: ACL.resource(agent.uid),
        action: "invoke"
      })

    {:ok, profile} =
      Profile.cast(%{
        "ai_agent" => %{
          "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
          "mission" => "Handle command tests.",
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

  defp append_assistant(conversation, trigger_message, text, external_id) do
    Conversations.append_message(conversation, %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :normal,
      status: :complete,
      content: [Message.text_block(text)],
      metadata:
        %{
          "generation" => %{
            "trigger_message_id" => trigger_message.id,
            "trigger_type" => "mailbox_entry",
            "trigger_id" => BullX.Ext.gen_uuid_v7()
          }
        }
        |> maybe_put_delivery(external_id)
    })
  end

  defp maybe_put_delivery(metadata, nil), do: metadata

  defp maybe_put_delivery(metadata, external_id),
    do: Map.put(metadata, "delivery", delivery_metadata(external_id))

  defp delivery_metadata(external_id) do
    %{
      "status" => "sent",
      "adapter_result_ref" =>
        Jason.encode!(%{
          "primary_external_id" => external_id,
          "external_message_ids" => [external_id]
        })
    }
  end

  defp command_context(conversation, caller, agent, profile, entry_id) do
    %{
      args: "",
      conversation_id: conversation.id,
      caller_principal_uid: caller.uid,
      agent_uid: agent.uid,
      profile: profile,
      trigger_type: "mailbox_entry",
      trigger_id: entry_id,
      mailbox_queue_key: BullX.Ext.gen_uuid_v7(),
      mailbox_entry_id: entry_id,
      acl_context: %{}
    }
  end
end
