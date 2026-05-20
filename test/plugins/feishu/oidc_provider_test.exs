defmodule Feishu.OIDCProviderTest do
  use ExUnit.Case, async: false

  alias Feishu.{OIDCProvider, Source}
  alias FeishuOpenAPI.{Client, TokenManager}

  @default_scope "auth:user_access_token:read offline_access component:user_profile auth:user.id:read"

  setup do
    :ets.delete_all_objects(FeishuOpenAPI.TokenStore.table())
    app_id = "cli_oidc_" <> Integer.to_string(:erlang.unique_integer([:positive]))

    client =
      Client.new(app_id, "secret_oidc", req_options: [plug: {Req.Test, __MODULE__}])

    source = %Source{
      id: "main",
      app_id: app_id,
      app_secret: "secret_oidc",
      client: client,
      domain: :feishu,
      oidc: %{
        "enabled" => true,
        "redirect_uri" => "https://bullx.example.com/sessions/oidc/main/callback"
      },
      req_options: [plug: {Req.Test, __MODULE__}]
    }

    {:ok, source: source}
  end

  defp allow_token_manager(client) do
    {:ok, manager_pid} =
      DynamicSupervisor.start_child(FeishuOpenAPI.TokenManager.Supervisor, {TokenManager, client})

    Req.Test.allow(__MODULE__, self(), manager_pid)
  end

  test "authorization_url returns a source-scoped state", %{source: source} do
    assert {:ok, %{url: url, state: state}} =
             OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert state["provider"] == "main"
    assert state["source_id"] == "main"
    assert state["return_to"] == "/console"
    assert URI.parse(url).host == "accounts.feishu.cn"
    assert url =~ "client_id=#{source.app_id}"
    assert URI.decode_query(URI.parse(url).query)["scope"] == @default_scope
  end

  test "authorization_url sends configured Feishu OpenAPI scopes", %{source: source} do
    source = %{
      source
      | oidc: Map.put(source.oidc, "scopes", ["auth:user_access_token:read"])
    }

    assert {:ok, %{url: url}} =
             OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert URI.decode_query(URI.parse(url).query)["scope"] == "auth:user_access_token:read"
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
            "expires_in" => 7200,
            "open_id" => "ou_user",
            "tenant_key" => "tenant_x"
          })

        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token",
            "expire" => 7200
          })

        "/open-apis/contact/v3/users/ou_user" ->
          assert conn.query_string == "user_id_type=open_id"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tenant_token"]

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "user" => %{
                "open_id" => "ou_user",
                "union_id" => "on_union",
                "user_id" => "user_x",
                "name" => "Ada",
                "email" => "ADA@example.com",
                "enterprise_email" => "ADA@corp.example.com",
                "mobile" => "13800000000",
                "avatar" => %{"avatar_240" => "https://example.com/avatar.png"}
              }
            }
          })

        path ->
          Req.Test.json(conn, %{"code" => 404, "msg" => "unexpected path #{path}"})
      end
    end)

    allow_token_manager(source.client)

    {:ok, %{state: state}} = OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert {:ok, subject} =
             OIDCProvider.callback(source, %{"code" => "auth_code"}, state)

    assert subject["provider"] == "main"
    assert subject["external_id"] == "feishu:ou_user"
    assert subject["profile"]["uid"] == "user_x"
    assert subject["profile"]["display_name"] == "Ada"
    assert subject["profile"]["email"] == "ada@corp.example.com"
    assert subject["profile"]["phone"] == "+8613800000000"
    assert subject["profile"]["avatar_url"] == "https://example.com/avatar.png"
    assert subject["metadata"]["adapter"] == "feishu"
    assert subject["metadata"]["tenant_key"] == "tenant_x"
  end

  test "callback prefers contact profile over token response profile fields", %{source: source} do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v2/oauth/token" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "access_token" => "user_token_contact",
            "refresh_token" => "refresh_token_contact",
            "token_type" => "Bearer",
            "expires_in" => 7200,
            "open_id" => "ou_user_contact",
            "name" => "Ada",
            "email" => "stale@example.com"
          })

        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token_contact",
            "expire" => 7200
          })

        "/open-apis/contact/v3/users/ou_user_contact" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "user" => %{
                "open_id" => "ou_user_contact",
                "user_id" => "user_contact",
                "name" => "Grace",
                "email" => "GRACE@example.com",
                "enterprise_email" => "GRACE@corp.example.com"
              }
            }
          })

        path ->
          Req.Test.json(conn, %{"code" => 404, "msg" => "unexpected path #{path}"})
      end
    end)

    allow_token_manager(source.client)

    {:ok, %{state: state}} = OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert {:ok, subject} =
             OIDCProvider.callback(source, %{"code" => "auth_code"}, state)

    assert subject["external_id"] == "feishu:ou_user_contact"
    assert subject["profile"]["uid"] == "user_contact"
    assert subject["profile"]["display_name"] == "Grace"
    assert subject["profile"]["email"] == "grace@corp.example.com"
  end

  test "callback can resolve contact profile through token response user_id", %{source: source} do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v2/oauth/token" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "access_token" => "user_token_user_id",
            "refresh_token" => "refresh_token_user_id",
            "token_type" => "Bearer",
            "expires_in" => 7200,
            "user_id" => "user_x"
          })

        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token_user_id",
            "expire" => 7200
          })

        "/open-apis/contact/v3/users/user_x" ->
          assert conn.query_string == "user_id_type=user_id"

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "user" => %{
                "open_id" => "ou_user_id",
                "user_id" => "user_x",
                "name" => "Lin"
              }
            }
          })

        path ->
          Req.Test.json(conn, %{"code" => 404, "msg" => "unexpected path #{path}"})
      end
    end)

    allow_token_manager(source.client)

    {:ok, %{state: state}} = OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert {:ok, subject} =
             OIDCProvider.callback(source, %{"code" => "auth_code"}, state)

    assert subject["external_id"] == "feishu:ou_user_id"
    assert subject["profile"]["display_name"] == "Lin"
  end

  test "callback falls back to authen user_info when token response lacks user id", %{
    source: source
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v2/oauth/token" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "access_token" => "user_token_fallback",
            "refresh_token" => "refresh_token_fallback",
            "token_type" => "Bearer",
            "expires_in" => 7200
          })

        "/open-apis/authen/v1/user_info" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user_token_fallback"]

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"open_id" => "ou_fallback"}
          })

        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "tenant_access_token" => "tenant_token_fallback",
            "expire" => 7200
          })

        "/open-apis/contact/v3/users/ou_fallback" ->
          assert conn.query_string == "user_id_type=open_id"

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{
              "user" => %{"open_id" => "ou_fallback", "name" => "Fallback User"}
            }
          })

        path ->
          Req.Test.json(conn, %{"code" => 404, "msg" => "unexpected path #{path}"})
      end
    end)

    allow_token_manager(source.client)

    {:ok, %{state: state}} = OIDCProvider.authorization_url(source, %{"return_to" => "/console"})

    assert {:ok, subject} =
             OIDCProvider.callback(source, %{"code" => "auth_code"}, state)

    assert subject["external_id"] == "feishu:ou_fallback"
    assert subject["profile"]["display_name"] == "Fallback User"
  end

  test "authorization_url fails closed when web login is disabled", %{source: source} do
    source = %{source | web_login_disabled?: true}

    assert {:error, %{"kind" => "config", "message" => "Feishu web login is disabled"}} =
             OIDCProvider.authorization_url(source, %{"return_to" => "/console"})
  end
end
