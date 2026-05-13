defmodule Feishu.ConfigTest do
  use ExUnit.Case, async: false

  alias BullX.Config.SecretKeys
  alias BullX.Gateway.SourceConfig
  alias Feishu.Source

  setup do
    previous_plugins = Application.get_env(:bullx, :plugins)

    Application.put_env(:bullx, :plugins, %{
      feishu: %{
        credentials: %{
          "default" => %{"app_id" => "cli_test", "app_secret" => "secret_test"}
        }
      }
    })

    SecretKeys.reset()

    on_exit(fn ->
      restore_env(:plugins, previous_plugins)
      SecretKeys.reset()
    end)

    :ok
  end

  test "credentials are declared as a BullX secret key" do
    assert SecretKeys.secret?("bullx.plugins.feishu.credentials")
  end

  test "normalizes a source by resolving a credential profile" do
    source_config = %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      config: %{
        "credential_id" => "default",
        "domain" => "lark",
        "tenant_key" => "tenant_1",
        "oidc" => %{
          "enabled" => true,
          "redirect_uri" => "https://bullx.example.com/sessions/oidc/main/callback",
          "scopes" => ["openid", "profile"]
        }
      }
    }

    assert {:ok, source} = Source.normalize(source_config)

    assert source.channel_id == "main"
    assert source.app_id == "cli_test"
    assert source.domain == :lark
    assert Source.oidc_enabled?(source)
    assert Source.oidc_scopes(source) == ["openid", "profile"]
    refute inspect(source) =~ "secret_test"
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
