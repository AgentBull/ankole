defmodule Ankole.Plugins.LarkAdapterMentionRoutingTest do
  use Ankole.DataCase, async: false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.InboundBatch
  alias FeishuOpenAPI.Event

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures, only: [finalize_due_inbound_batch_events: 1]

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @base_ms DateTime.to_unix(@base_time, :millisecond)

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Req.default_options()
    Req.Test.stub(__MODULE__, &default_lark_request/1)
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
  end

  describe "runtime bot mention routing" do
    test "message receive ignores a group mention when bot identity is not resolved" do
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

    test "message receive ignores a group mention for another bot" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"runtimeBotOpenID" => "ou_this_bot"})
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

    test "message receive accepts a group mention for the resolved runtime bot identity" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"runtimeBotOpenID" => "ou_this_bot"})
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

    test "message receive uses only the runtime bot open_id" do
      config = chat_config(%{"runtimeBotOpenID" => "ou_this_bot"})

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
    end

    test "message receive strips the current bot mention from visible addressed text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"runtimeBotOpenID" => "ou_this_bot"})
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

    test "mention-only reply resolves its persisted parent file only for the binding that observed it" do
      %{principal: agent_a} = agent_fixture()
      %{principal: agent_b} = agent_fixture()
      binding_fixture(agent_a.uid, "lark", :ignore)
      binding_fixture(agent_b.uid, "lark", :ignore)

      consumer_a =
        agent_a.uid
        |> adapter_context()
        |> Inbound.chat_consumer(chat_config(%{"runtimeBotOpenID" => "ou_agent_a"}))

      consumer_b =
        agent_b.uid
        |> adapter_context()
        |> Inbound.chat_consumer(chat_config(%{"runtimeBotOpenID" => "ou_agent_b"}))

      parent_file =
        receive_event()
        |> Map.put(:id, "evt_parent_file")
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_parent_file",
              "message_type" => "file",
              "content" => ~s({"file_key":"file_parent","file_name":"strategy.pdf"}),
              "mentions" => []
          }
        end)

      assert {:ok, parent_results} =
               Inbound.handle_message_receive(
                 "im.message.receive_v1",
                 parent_file,
                 [consumer_a]
               )

      assert Enum.all?(parent_results, &match?(%{inbound_batch: %InboundBatch{}}, &1))

      parent_batches = Repo.all(InboundBatch)
      assert length(parent_batches) == 1

      parent_due_at =
        parent_batches
        |> Enum.max_by(&DateTime.to_unix(&1.available_at, :microsecond))
        |> Map.fetch!(:available_at)

      assert {:ok, finalized_parent_results} =
               finalize_due_inbound_batch_events(now: parent_due_at)

      assert Enum.all?(finalized_parent_results, &(&1.status == :ignored))
      assert Enum.all?(Repo.all(InboundBatch), &(&1.outcome == "no_actor_event"))

      assert [
               %{
                 "source_entry_id" => "om_parent_file",
                 "attachments" => [
                   %{
                     "provider_ref" => "lark:file:file_parent",
                     "source_message_id" => "om_parent_file"
                   }
                 ]
               }
             ] = hd(parent_batches).entries

      reply =
        receive_event()
        |> Map.put(:id, "evt_reply_agent_a")
        |> update_message(fn message ->
          Map.merge(message, %{
            "message_id" => "om_reply_agent_a",
            "parent_id" => "om_parent_file",
            "root_id" => "om_parent_file",
            "content" => ~s({"text":"@_agent_a"}),
            "mentions" => [
              %{
                "key" => "@_agent_a",
                "name" => "Agent A",
                "id" => %{"open_id" => "ou_agent_a"}
              }
            ],
            "create_time" => Integer.to_string(@base_ms + 10_000)
          })
        end)

      assert {:ok,
              %{
                attachments: [],
                reply_to_source_entry_id: "om_parent_file",
                explicit: true,
                text: nil
              }} =
               Inbound.normalize_message_receive(reply, consumer_a)

      assert {:ok,
              %{
                attachments: [],
                reply_to_source_entry_id: "om_parent_file",
                explicit: false
              }} =
               Inbound.normalize_message_receive(reply, consumer_b)

      assert {:ok, reply_results} =
               Inbound.handle_message_receive(
                 "im.message.receive_v1",
                 reply,
                 [consumer_a, consumer_b]
               )

      assert Enum.any?(reply_results, &(&1.status == :accepted))
      assert Enum.any?(reply_results, &(&1.status == :ignored))
      refute_receive {:materialized, _source_message_ids}, 10

      reply_batches = Enum.filter(Repo.all(InboundBatch), &(&1.batch_state == "open"))
      assert length(reply_batches) == 2

      reply_due_at =
        reply_batches
        |> Enum.max_by(&DateTime.to_unix(&1.available_at, :microsecond))
        |> Map.fetch!(:available_at)

      assert {:ok, finalized_reply_results} =
               finalize_due_inbound_batch_events(now: reply_due_at)

      assert [
               %{
                 actor_event:
                   %ActorEvent{
                     agent_uid: agent_a_uid,
                     source_entry_id: "om_reply_agent_a"
                   } = actor_event
               }
             ] = Enum.filter(finalized_reply_results, &Map.has_key?(&1, :actor_event))

      assert agent_a_uid == agent_a.uid

      assert get_in(actor_event.payload, ["data", "entry", "attachments"]) == []

      assert %{
               "source_entry_id" => "om_parent_file",
               "resolution" => "resolved",
               "attachments" => [
                 %{
                   "provider_ref" => "lark:file:file_parent",
                   "source_message_id" => "om_parent_file",
                   "name" => "strategy.pdf"
                 }
               ]
             } = get_in(actor_event.payload, ["data", "entry", "reply_to"])

      refute Repo.get_by(ActorEvent,
               agent_uid: agent_b.uid,
               source_entry_id: "om_reply_agent_a"
             )

      reply_for_agent_b =
        reply
        |> Map.put(:id, "evt_reply_agent_b")
        |> update_message(fn message ->
          Map.merge(message, %{
            "message_id" => "om_reply_agent_b",
            "content" => ~s({"text":"@_agent_b"}),
            "mentions" => [
              %{
                "key" => "@_agent_b",
                "name" => "Agent B",
                "id" => %{"open_id" => "ou_agent_b"}
              }
            ],
            "create_time" => Integer.to_string(@base_ms + 15_000)
          })
        end)

      assert {:ok, [%{status: :accepted}]} =
               Inbound.handle_message_receive(
                 "im.message.receive_v1",
                 reply_for_agent_b,
                 [consumer_b]
               )

      [agent_b_batch] =
        InboundBatch
        |> Repo.all()
        |> Enum.filter(&(&1.agent_uid == agent_b.uid and &1.batch_state == "open"))

      assert {:ok, agent_b_results} =
               finalize_due_inbound_batch_events(now: agent_b_batch.available_at)

      assert [
               %{
                 actor_event:
                   %ActorEvent{
                     agent_uid: agent_b_uid,
                     source_entry_id: "om_reply_agent_b"
                   } = agent_b_event
               }
             ] = Enum.filter(agent_b_results, &Map.has_key?(&1, :actor_event))

      assert agent_b_uid == agent_b.uid

      assert %{
               "source_entry_id" => "om_parent_file",
               "resolution" => "unresolved"
             } = get_in(agent_b_event.payload, ["data", "entry", "reply_to"])

      refute Map.has_key?(
               get_in(agent_b_event.payload, ["data", "entry", "reply_to"]),
               "attachments"
             )

      refute_receive {:materialized, _source_message_ids}, 10

      mention_without_reply =
        receive_event()
        |> Map.put(:id, "evt_mention_without_reply")
        |> update_message(fn message ->
          %{
            message
            | "message_id" => "om_mention_without_reply",
              "content" => ~s({"text":"@_agent_a"}),
              "mentions" => [
                %{
                  "key" => "@_agent_a",
                  "name" => "Agent A",
                  "id" => %{"open_id" => "ou_agent_a"}
                }
              ],
              "create_time" => Integer.to_string(@base_ms + 20_000)
          }
        end)

      assert {:ok, %{explicit: true, text: nil, attachments: []}} =
               Inbound.normalize_message_receive(mention_without_reply, consumer_a)
    end

    test "direct messages are explicit with or without structured mentions" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "lark", :ignore)

      consumer =
        Inbound.chat_consumer(
          adapter_context(agent.uid),
          chat_config(%{"runtimeBotOpenID" => "ou_this_bot"})
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
    {runtime_bot_open_id, overrides} = Map.pop(overrides, "runtimeBotOpenID")

    {:ok, config} =
      %{
        "appID" => "cli_test",
        "appSecret" => "secret",
        "platformSubjectNamespace" => "lark-main"
      }
      |> Map.merge(overrides)
      |> Config.validate_chat_config()

    case runtime_bot_open_id do
      nil -> config
      open_id -> Map.put(config, "runtimeBotOpenID", open_id)
    end
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

  defp default_lark_request(
         %{request_path: "/open-apis/auth/v3/tenant_access_token/internal"} = conn
       ) do
    Req.Test.json(conn, %{
      "code" => 0,
      "tenant_access_token" => "tenant-token",
      "expire" => 7_200
    })
  end

  defp default_lark_request(conn) do
    conn
    |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="resource.bin"))
    |> Plug.Conn.send_resp(200, "attachment")
  end
end
