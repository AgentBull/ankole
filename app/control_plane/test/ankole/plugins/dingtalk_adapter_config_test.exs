defmodule Ankole.Plugins.DingTalkAdapterConfigTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.DingTalkAdapter.Config

  test "validate_chat_config normalizes required and defaulted fields" do
    assert {:ok, config} =
             Config.validate_chat_config(%{
               "clientId" => "ding-app",
               "clientSecret" => "secret"
             })

    assert config["clientId"] == "ding-app"
    assert config["group_message_mode"] == "addressed_only"
    assert config["platformSubjectNamespace"] == "dingtalk-main"
    assert config["userName"] == "钉钉 / DingTalk"
    assert config["robotCode"] == nil
    assert config["cardTemplateId"] == nil
  end

  test "validate_chat_config rejects a missing clientId and an unknown group mode" do
    assert {:error, {:missing, "clientId"}} =
             Config.validate_chat_config(%{"clientSecret" => "s"})

    assert {:error, {:invalid_enum, "group_message_mode", _}} =
             Config.validate_chat_config(%{
               "clientId" => "a",
               "clientSecret" => "s",
               "group_message_mode" => "observe_all"
             })
  end

  test "validate_identity_config defaults sync and scope, forcing websocket under contacts" do
    assert {:ok, config} =
             Config.validate_identity_config(%{
               "clientId" => "a",
               "clientSecret" => "s",
               "sync" => %{"contacts" => false, "websocket" => true}
             })

    assert config["oidc"] == %{"enabled" => true, "scope" => "openid corpid"}
    assert config["sync"]["websocket"] == false
    assert config["sync"]["pageSize"] == 50
  end

  test "validate_identity_config rejects an out-of-range page size and a bad scope" do
    assert {:error, {:invalid_integer_range, "pageSize", 1, 100}} =
             Config.validate_identity_config(%{
               "clientId" => "a",
               "clientSecret" => "s",
               "sync" => %{"pageSize" => 500}
             })

    assert {:error, {:invalid_enum, "scope", _}} =
             Config.validate_identity_config(%{
               "clientId" => "a",
               "clientSecret" => "s",
               "oidc" => %{"scope" => "email"}
             })
  end

  test "connection_key is domain-tagged by clientId" do
    assert Config.connection_key(%{"clientId" => "ding-app"}) == {"dingtalk", "ding-app"}
  end

  test "effective_robot_code falls back to the clientId" do
    assert Config.effective_robot_code(%{"clientId" => "ding-app", "robotCode" => nil}) ==
             "ding-app"

    assert Config.effective_robot_code(%{"clientId" => "ding-app", "robotCode" => "robot-x"}) ==
             "robot-x"
  end

  test "client builds a DingTalkOpenAPI client with provider endpoints" do
    config = %{
      "clientId" => "ding-app",
      "clientSecret" => "secret"
    }

    client = Config.client(config)
    assert %DingTalkOpenAPI.Client{} = client
    assert client.api_base_url == "https://api.dingtalk.com"
    assert client.oapi_base_url == "https://oapi.dingtalk.com"
    refute inspect(client) =~ "secret"
  end
end
