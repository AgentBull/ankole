defmodule Feishu.OIDCProviderTest do
  use ExUnit.Case, async: true

  alias Feishu.{OIDCProvider, Source}

  setup do
    source = %Source{
      id: "main",
      app_id: "cli_oidc",
      app_secret: "secret_oidc",
      domain: :feishu,
      oidc: %{
        "enabled" => true,
        "scopes" => ["openid", "profile", "email"],
        "redirect_uri" => "https://bullx.example.com/sessions/oidc/main/callback"
      },
      req_options: [plug: {Req.Test, __MODULE__}]
    }

    {:ok, source: source}
  end

  test "authorization_url returns a source-scoped state", %{source: source} do
    assert {:ok, %{url: url, state: state}} =
             OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert state["provider"] == "main"
    assert state["source_id"] == "main"
    assert state["return_to"] == "/console"
    assert URI.parse(url).host == "accounts.feishu.cn"
    assert url =~ "client_id=cli_oidc"
  end

  test "callback exchanges code and returns a Principal login subject", %{source: source} do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v2/oauth/token" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "access_token" => "user_token",
            "refresh_token" => "refresh_token",
            "token_type" => "Bearer",
            "expires_in" => 7200
          })

        "/open-apis/authen/v1/user_info" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "open_id" => "ou_user",
              "union_id" => "on_union",
              "name" => "Ada",
              "email" => "ADA@example.com"
            }
          })
      end
    end)

    {:ok, %{state: state}} = OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert {:ok, subject} =
             OIDCProvider.callback(source, %{"code" => "auth_code"}, state)

    assert subject["provider"] == "main"
    assert subject["external_id"] == "feishu:ou_user"
    assert subject["profile"]["display_name"] == "Ada"
    assert subject["profile"]["email"] == "ada@example.com"
    assert subject["metadata"]["adapter"] == "feishu"
  end

  test "authorization_url fails closed when web login is disabled", %{source: source} do
    source = %{source | web_login_disabled?: true}

    assert {:error, %{"kind" => "config", "message" => "Feishu web login is disabled"}} =
             OIDCProvider.authorization_url(source, %{"return_to" => "/console"})
  end
end
