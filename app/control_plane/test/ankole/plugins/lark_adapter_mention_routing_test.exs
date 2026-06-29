defmodule Ankole.Plugins.LarkAdapterMentionRoutingTest do
  use Ankole.DataCase, async: false

  alias Ankole.Actors.ActorInput
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias FeishuOpenAPI.Event

  import Ankole.PrincipalsFixtures

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @base_ms DateTime.to_unix(@base_time, :millisecond)

  describe "configured bot mention routing" do
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
                  "key" => "_other_bot",
                  "name" => "Other Bot",
                  "id" => %{"open_id" => "ou_other_bot"}
                }
              ]
          }
        end)

      assert {:ok, [%{status: :ignored}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      refute Repo.get_by(ActorInput, provider_entry_id: "om_other_bot_mention")

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
                  "key" => "_this_bot",
                  "name" => "This Bot",
                  "id" => %{"open_id" => "ou_this_bot"}
                }
              ]
          }
        end)

      assert {:ok, [%{status: :accepted, actor_input: input}]} =
               Inbound.handle_message_receive("im.message.receive_v1", event, [consumer])

      assert input.type == "command.retry"
      assert input.provider_entry_id == "om_this_bot_mention"

      assert {:ok, %{mentions: [%{"agent_uid" => agent_uid}], explicit: true}} =
               Inbound.normalize_message_receive(event, consumer)

      assert agent_uid == agent.uid
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
