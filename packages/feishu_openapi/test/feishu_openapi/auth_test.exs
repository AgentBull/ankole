defmodule FeishuOpenAPI.AuthTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.Auth

  setup do
    client =
      FeishuOpenAPI.new("cli_auth", "secret_x",
        req_options: [plug: {Req.Test, FeishuOpenAPI.AuthTest}]
      )

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
      assert conn.request_path == "/open-apis/authen/v2/oauth/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "grant_type" => "authorization_code",
               "client_id" => "cli_auth",
               "client_secret" => "secret_x",
               "code" => "code_x"
             } = Jason.decode!(body)

      Req.Test.json(conn, %{
        "code" => 0,
        "access_token" => "eyJ...",
        "refresh_token" => "refresh_x",
        "token_type" => "Bearer",
        "expires_in" => 7200,
        "refresh_token_expires_in" => 2_592_000,
        "scope" => "contact:user.base:readonly"
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
      assert conn.request_path == "/open-apis/authen/v2/oauth/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "grant_type" => "refresh_token",
               "client_id" => "cli_auth",
               "client_secret" => "secret_x",
               "refresh_token" => "refresh_x"
             } = Jason.decode!(body)

      Req.Test.json(conn, %{
        "code" => 0,
        "access_token" => "eyJ.new",
        "refresh_token" => "refresh_new",
        "token_type" => "Bearer",
        "expires_in" => 7200
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
