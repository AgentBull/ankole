defmodule DingTalkOpenAPI.OAuthTest do
  # async: false — the getbyunionid path resolves a shared-ETS app token.
  use ExUnit.Case, async: false

  alias DingTalkOpenAPI.{Client, Error, OAuth}

  setup do
    client =
      Client.new(
        client_id: "ding-oauth",
        client_secret: "secret",
        api_base_url: "https://api.dingtalk.test",
        oapi_base_url: "https://oapi.dingtalk.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    key = {:app, Client.cache_namespace(client)}

    :ets.insert(
      DingTalkOpenAPI.TokenStore.table(),
      {key, "atok", System.monotonic_time(:millisecond) + :timer.hours(1)}
    )

    on_exit(fn -> :ets.delete(DingTalkOpenAPI.TokenStore.table(), key) end)

    %{client: client}
  end

  test "authorize_url carries the DingTalk login params including authCode-style response_type" do
    url =
      OAuth.authorize_url(
        client_id: "ding-app",
        redirect_uri: "https://ankole.test/callback",
        state: "s1",
        authorize_url: "https://login.dingtalk.test/oauth2/auth"
      )

    assert String.starts_with?(url, "https://login.dingtalk.test/oauth2/auth?")
    params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert params["client_id"] == "ding-app"
    assert params["redirect_uri"] == "https://ankole.test/callback"
    assert params["response_type"] == "code"
    assert params["scope"] == "openid corpid"
    assert params["prompt"] == "consent"
    assert params["state"] == "s1"
  end

  test "exchange_code posts the authCode and unwraps the user token plus corpId", %{
    client: client
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/oauth2/userAccessToken"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Torque.decode!(body) == %{
               "clientId" => "ding-oauth",
               "clientSecret" => "secret",
               "code" => "authcode-1",
               "grantType" => "authorization_code"
             }

      Req.Test.json(conn, %{
        "accessToken" => "u-tok",
        "refreshToken" => "r-tok",
        "expireIn" => 7200,
        "corpId" => "corp-1"
      })
    end)

    assert {:ok, %{access_token: "u-tok", refresh_token: "r-tok", corp_id: "corp-1"}} =
             OAuth.exchange_code(client, "authcode-1")
  end

  test "me reads the profile with the user access token in the header", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/contact/users/me"
      assert Plug.Conn.get_req_header(conn, "x-acs-dingtalk-access-token") == ["u-tok"]
      Req.Test.json(conn, %{"unionId" => "union-1", "nick" => "Ada"})
    end)

    assert {:ok, %{"unionId" => "union-1"}} = OAuth.me(client, "u-tok")
  end

  test "get_userid_by_unionid resolves the enterprise userid over the old domain", %{
    client: client
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "oapi.dingtalk.test"
      assert conn.request_path == "/topapi/user/getbyunionid"
      Req.Test.json(conn, %{"errcode" => 0, "result" => %{"userid" => "staff-1"}})
    end)

    assert {:ok, "staff-1"} = OAuth.get_userid_by_unionid(client, "union-1")
  end

  test "get_userid_by_unionid surfaces 60121 as not_found", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errcode" => 60_121, "errmsg" => "not found"})
    end)

    assert {:error, %Error{reason: :not_found}} = OAuth.get_userid_by_unionid(client, "union-x")
  end
end
