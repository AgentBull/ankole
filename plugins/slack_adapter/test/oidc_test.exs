defmodule SlackOpenAPI.OIDCTest do
  use ExUnit.Case, async: true

  alias SlackOpenAPI.OIDC

  test "authorize URL includes required OIDC parameters and optional team" do
    url =
      OIDC.authorize_url(
        client_id: "client",
        redirect_uri: "https://ankole.test/callback",
        state: "state",
        scopes: ["openid", "profile", "email"],
        team: "T1"
      )

    uri = URI.parse(url)
    assert uri.path == "/openid/connect/authorize"

    assert URI.decode_query(uri.query) == %{
             "client_id" => "client",
             "redirect_uri" => "https://ankole.test/callback",
             "response_type" => "code",
             "scope" => "openid profile email",
             "state" => "state",
             "team" => "T1"
           }
  end

  test "code exchange and userInfo use Slack endpoints" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/openid.connect.token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert URI.decode_query(body)["code"] == "code"
          Req.Test.json(conn, %{"ok" => true, "access_token" => "xoxp-user", "id_token" => "jwt"})

        "/api/openid.connect.userInfo" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxp-user"]
          Req.Test.json(conn, %{"ok" => true, "sub" => "U1", "email" => "u@example.com"})
      end
    end)

    client =
      SlackOpenAPI.Client.new(
        base_url: "https://slack.test/api",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    assert {:ok, %{access_token: "xoxp-user", id_token: "jwt"}} =
             OIDC.exchange_code(client,
               client_id: "client",
               client_secret: "secret",
               code: "code",
               redirect_uri: "https://ankole.test/callback"
             )

    assert {:ok, %{"sub" => "U1"}} =
             OIDC.user_info("xoxp-user",
               base_url: "https://slack.test/api",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end
end
