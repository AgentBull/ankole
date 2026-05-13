defmodule Feishu.OIDCProviderTest do
  use ExUnit.Case, async: false

  alias BullX.Gateway.SourceConfig
  alias Feishu.OIDCProvider

  setup do
    previous_plugins = Application.get_env(:bullx, :plugins)

    Application.put_env(:bullx, :plugins, %{
      feishu: %{
        credentials: %{
          "default" => %{"app_id" => "cli_test", "app_secret" => "secret_test"}
        }
      }
    })

    on_exit(fn -> restore_env(:plugins, previous_plugins) end)

    :ok
  end

  test "authorization_url uses the source slug as provider state" do
    source = source_config()

    assert {:ok, %{url: url, state: state}} =
             OIDCProvider.authorization_url(source, %{
               "return_to" => "/work",
               "state_token" => "signed-state"
             })

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.host == "accounts.feishu.cn"
    assert query["client_id"] == "cli_test"
    assert query["state"] == "signed-state"
    assert state["provider"] == "main"
    assert state["channel_id"] == "main"
    assert state["return_to"] == "/work"
  end

  test "callback normalizes a Principal login subject and discards tokens" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v2/oauth/token" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "access_token" => "user-token",
              "refresh_token" => "refresh-token",
              "expires_in" => 3600
            }
          })

        "/open-apis/authen/v1/user_info" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "open_id" => "ou_user",
              "union_id" => "on_user",
              "name" => "Alice",
              "email" => "ALICE@example.COM",
              "tenant_key" => "tenant_1"
            }
          })
      end
    end)

    state = %{
      "provider" => "main",
      "adapter" => "feishu",
      "channel_id" => "main",
      "return_to" => "/",
      "issued_at" => System.system_time(:second),
      "nonce" => "nonce"
    }

    assert {:ok, subject} =
             OIDCProvider.callback(
               source_config(%{"req_options" => [plug: {Req.Test, __MODULE__}]}),
               %{"code" => "auth-code"},
               state
             )

    assert subject["provider"] == "main"
    assert subject["external_id"] == "feishu:ou_user"
    assert subject["profile"]["email"] == "alice@example.com"
    assert subject["metadata"]["adapter"] == "feishu"
    refute inspect(subject) =~ "user-token"
    refute inspect(subject) =~ "refresh-token"
  end

  defp source_config(extra \\ %{}) do
    %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      config:
        Map.merge(
          %{
            "credential_id" => "default",
            "domain" => "feishu",
            "oidc" => %{
              "enabled" => true,
              "redirect_uri" => "https://bullx.example.com/sessions/oidc/main/callback",
              "scopes" => ["openid", "profile", "email"]
            }
          },
          extra
        )
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
