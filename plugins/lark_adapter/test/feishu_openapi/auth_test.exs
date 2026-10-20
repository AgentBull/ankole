defmodule FeishuOpenAPI.AuthTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.{Auth, Client, TokenStore}

  setup do
    app_id = "cli_auth_#{System.unique_integer([:positive])}"

    client =
      FeishuOpenAPI.new(app_id, "secret_x",
        req_options: [plug: {Req.Test, FeishuOpenAPI.AuthTest}]
      )

    :ets.insert(
      TokenStore.table(),
      {{:tenant, Client.cache_namespace(client), nil}, "t-auth", :infinity}
    )

    on_exit(fn ->
      :ets.delete(TokenStore.table(), {:tenant, Client.cache_namespace(client), nil})
    end)

    {:ok, client: client}
  end

  test "auth responses without the token field are rejected", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.AuthTest, fn conn ->
      assert conn.request_path == "/open-apis/auth/v3/app_access_token/internal"
      Req.Test.json(conn, %{"code" => 0, "expire" => 7200})
    end)

    assert {:error, %FeishuOpenAPI.Error{code: :unexpected_shape}} =
             Auth.app_access_token(client)
  end

  test "user_access_token normalizes the OIDC response", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.AuthTest, fn conn ->
      assert conn.request_path == "/open-apis/authen/v1/oidc/access_token"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t-auth"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "grant_type" => "authorization_code",
               "code" => "code_x"
             } = Torque.decode!(body)

      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "access_token" => "eyJ...",
          "refresh_token" => "refresh_x",
          "token_type" => "Bearer",
          "expires_in" => 7200,
          "refresh_token_expires_in" => 2_592_000,
          "scope" => "contact:user.base:readonly"
        }
      })
    end)

    assert {:ok,
            %{
              access_token: "eyJ...",
              refresh_token: "refresh_x",
              token_type: "Bearer",
              expires_in: 7200,
              refresh_expires_in: 2_592_000,
              scope: "contact:user.base:readonly"
            }} = Auth.user_access_token(client, "code_x")
  end

  test "refresh_user_access_token normalizes the OIDC response", %{client: client} do
    Req.Test.stub(FeishuOpenAPI.AuthTest, fn conn ->
      assert conn.request_path == "/open-apis/authen/v1/oidc/refresh_access_token"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t-auth"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "grant_type" => "refresh_token",
               "refresh_token" => "refresh_x"
             } = Torque.decode!(body)

      Req.Test.json(conn, %{
        "code" => 0,
        "data" => %{
          "access_token" => "eyJ.new",
          "refresh_token" => "refresh_new",
          "token_type" => "Bearer",
          "expires_in" => 7200
        }
      })
    end)

    assert {:ok,
            %{
              access_token: "eyJ.new",
              refresh_token: "refresh_new",
              token_type: "Bearer",
              expires_in: 7200
            }} = Auth.refresh_user_access_token(client, "refresh_x")
  end
end
