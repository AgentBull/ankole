defmodule BullXFeishu.ConfigTest do
  use ExUnit.Case, async: false

  alias BullXFeishu.Config

  setup do
    System.put_env("BULLX_TEST_FEISHU_APP_ID", "cli_test")
    System.put_env("BULLX_TEST_FEISHU_APP_SECRET", "secret_test")

    on_exit(fn ->
      System.delete_env("BULLX_TEST_FEISHU_APP_ID")
      System.delete_env("BULLX_TEST_FEISHU_APP_SECRET")
    end)

    :ok
  end

  test "normalizes Feishu config and resolves system env indirection" do
    assert {:ok, config} =
             Config.normalize({:feishu, "default"}, %{
               app_id: {:system, "BULLX_TEST_FEISHU_APP_ID"},
               app_secret: {:system, "BULLX_TEST_FEISHU_APP_SECRET"},
               domain: "lark",
               dedupe_ttl_ms: 123,
               sso: %{
                 scopes: ["openid", "profile"]
               }
             })

    assert config.channel == {:feishu, "default"}
    assert config.app_id == "cli_test"
    assert config.app_secret == "secret_test"
    assert Config.web_login_allowed?(config)
    assert config.domain == :lark
    assert config.dedupe_ttl_ms == 123
    assert config.sso.scopes == ["openid", "profile"]
  end

  test "redacts secrets from exported config maps" do
    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        app_id: "cli_test",
        app_secret: "secret_test"
      })

    redacted = Config.redacted(config)

    refute Map.has_key?(redacted, :app_secret)
    refute Map.has_key?(redacted, :verification_token)
    refute Map.has_key?(redacted, :encrypt_key)
  end

  test "rejects unsupported domains" do
    assert {:error, %{"details" => %{"field" => "domain"}}} =
             Config.normalize({:feishu, "default"}, %{
               app_id: "cli_test",
               app_secret: "secret_test",
               domain: "https://example.test"
             })
  end
end
