defmodule Ankole.Plugins.LarkAdapterMentionRoutingTest do
  use Ankole.DataCase, async: false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias FeishuOpenAPI.Event

  import Ankole.PrincipalsFixtures

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @base_ms DateTime.to_unix(@base_time, :millisecond)

  describe "configured bot mention routing" do
    test "message receive ignores a group mention when bot identity is not configured" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{})
        )

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_unconfigured_bot_mention",
              "content" => ~s({"text":"@_some_bot /retry"}),
              "mentions" => [
                %{
                  "key" => "@_some_bot",
                  "name" => "Some Bot",
                  "id" => %{"open_id" => "ou_some_bot"}
                }
              ]
          }
        end)

      assert {:ok, [%{status: :ignored}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      refute Repo.get_by(ActorEvent, source_entry_id: "om_unconfigured_bot_mention")

      assert {:ok, %{mentions: [mention], explicit: false}} =
               Inbound.normalize_message_receive(event, consumer)

      refute Map.has_key?(mention, "agent_uid")
      assert mention["targets_current_agent"] == false
    end

    test "message receive ignores a group mention for another configured bot" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"botOpenId" => "ou_this_bot"})
        )

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_other_bot_mention",
              "content" => ~s({"text":"@_other_bot /retry"}),
              "mentions" => [
                %{
                  "key" => "@_other_bot",
                  "name" => "Other Bot",
                  "id" => %{"open_id" => "ou_other_bot"}
                }
              ]
          }
        end)

      assert {:ok, [%{status: :ignored}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      refute Repo.get_by(ActorEvent, source_entry_id: "om_other_bot_mention")

      assert {:ok, %{mentions: [mention], explicit: false}} =
               Inbound.normalize_message_receive(event, consumer)

      refute Map.has_key?(mention, "agent_uid")
      assert mention["targets_current_agent"] == false
    end

    test "message receive accepts a group mention for the configured bot identity" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"botOpenId" => "ou_this_bot"})
        )

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_this_bot_mention",
              "content" => ~s({"text":"@_this_bot /retry"}),
              "mentions" => [
                %{
                  "key" => "@_this_bot",
                  "name" => "This Bot",
                  "id" => %{"open_id" => "ou_this_bot"}
                }
              ]
          }
        end)

      assert {:ok, [%{status: :accepted, actor_event: input}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert input.type == "command.retry"
      assert input.source_entry_id == "om_this_bot_mention"

      assert {:ok, %{mentions: [%{"agent_uid" => agent_uid}], explicit: true, text: "/retry"}} =
               Inbound.normalize_message_receive(event, consumer)

      assert agent_uid == agent.uid
    end

    test "message receive accepts runtime bot identity resolved from configured bot user id" do
      config =
        %{"botUserId" => "cli_this_bot"}
        |> chat_config()
        |> Map.put("runtimeBotOpenId", "ou_this_bot")

      consumer = Inbound.chat_consumer(adapter_context("agentbull"), config)

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_runtime_bot_identity",
              "content" => ~s({"text":"@_this_bot /retry"}),
              "mentions" => [
                %{
                  "key" => "@_this_bot",
                  "name" => "This Bot",
                  "id" => %{"open_id" => "ou_this_bot"}
                }
              ]
          }
        end)

      assert {:ok, %{mentions: [%{"agent_uid" => agent_uid}], explicit: true, text: "/retry"}} =
               Inbound.normalize_message_receive(event, consumer)

      assert agent_uid == "agentbull"
      assert config["botOpenId"] == nil
    end

    test "message receive strips the current bot mention from visible addressed text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"botOpenId" => "ou_this_bot"})
        )

      event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_this_bot_visible_text",
              "content" => ~s({"text":"@_user_1 请回复 M1_A_OK。"}),
              "mentions" => [
                %{
                  "key" => "@_user_1",
                  "name" => "Agent A",
                  "id" => %{"open_id" => "ou_this_bot"}
                }
              ]
          }
        end)

      assert {:ok, %{mentions: [%{"agent_uid" => agent_uid}], explicit: true, text: text}} =
               Inbound.normalize_message_receive(event, consumer)

      assert agent_uid == agent.uid
      assert text == "请回复 M1_A_OK。"
      refute text =~ "_user_1"
    end

    test "direct messages are explicit with or without structured mentions" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"botOpenId" => "ou_this_bot"})
        )

      no_mention_event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_dm_no_mention",
              "chat_type" => "p2p",
              "content" => ~s({"text":"请回复 DM_OK。"}),
              "mentions" => []
          }
        end)

      assert {:ok, %{explicit: true, text: "请回复 DM_OK。", mentions: []}} =
               Inbound.normalize_message_receive(no_mention_event, consumer)

      mention_event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_dm_with_mention",
              "chat_type" => "p2p",
              "content" => ~s({"text":"@_user_1 请回复 DM_MENTION_OK。"}),
              "mentions" => [
                %{
                  "key" => "@_user_1",
                  "name" => "Agent A",
                  "id" => %{"open_id" => "ou_this_bot"}
                }
              ]
          }
        end)

      assert {:ok, %{explicit: true, text: text, mentions: [%{"agent_uid" => agent_uid}]}} =
               Inbound.normalize_message_receive(mention_event, consumer)

      assert agent_uid == agent.uid
      assert text == "请回复 DM_MENTION_OK。"
      refute text =~ "_user_1"

      contact_mention_event =
        receive_event()
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_dm_contact_mention",
              "chat_type" => "p2p",
              "content" => ~s({"text":"帮我发邮件给 @_user_2，同步一下合同进度。"}),
              "mentions" => [
                %{
                  "key" => "@_user_2",
                  "name" => "张三",
                  "id" => %{"open_id" => "ou_zhangsan"}
                }
              ]
          }
        end)

      assert {:ok, %{explicit: true, text: text, mentions: [contact_mention]}} =
               Inbound.normalize_message_receive(contact_mention_event, consumer)

      assert contact_mention["targets_current_agent"] == false
      assert text == "帮我发邮件给 张三，同步一下合同进度。"
      refute text =~ "_user_2"
    end
  end

  defp binding_fixture(agent_uid, name, policy) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: "lark",
        config_ref: "app-config://#{Config.chat_config_key(name)}",
        filters: %{},
        unaddressed_group_message_policy: policy
      })

    binding
  end

  defp adapter_context(agent_uid) do
    AdapterContext.new(
      agent_uid: agent_uid,
      binding_name: "lark",
      adapter: "lark",
      user_name: "Lark Bot"
    )
  end

  defp chat_config(overrides) do
    {:ok, config} =
      %{
        "appId" => "cli_test",
        "appSecret" => "secret",
        "platformSubjectNamespace" => "lark-main"
      }
      |> Map.merge(overrides)
      |> Config.validate_chat_config()

    config
  end

  defp receive_event do
    %Event{
      id: "evt_receive",
      type: "im.message.receive_v1",
      tenant_key: "tenant-a",
      app_id: "cli_test",
      created_at: @base_time,
      content: %{
        "sender" => %{
          "sender_type" => "user",
          "sender_name" => "Alice",
          "sender_id" => %{
            "user_id" => "ou_alice",
            "open_id" => "ou_open_alice",
            "union_id" => "onion_alice"
          }
        },
        "message" => %{
          "message_id" => "om_1",
          "chat_id" => "oc_group",
          "chat_type" => "group",
          "message_type" => "text",
          "content" => ~s({"text":"@_this_bot /retry"}),
          "mentions" => [
            %{"key" => "@_this_bot", "name" => "This Bot", "id" => %{"open_id" => "ou_this_bot"}}
          ],
          "create_time" => Integer.to_string(@base_ms)
        }
      },
      raw: %{"schema" => "2.0"}
    }
  end

  defp update_message(%Event{content: content} = event, fun) when is_function(fun, 1) do
    %{event | content: Map.update!(content, "message", fun)}
  end
end
