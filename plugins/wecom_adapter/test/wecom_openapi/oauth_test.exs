defmodule WeComOpenAPI.OAuthTest do
  use ExUnit.Case, async: true

  alias WeComOpenAPI.Corp.Client
  alias WeComOpenAPI.{Error, OAuth}

  defp client(responder) do
    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/cgi-bin/gettoken" ->
          Req.Test.json(conn, %{"errcode" => 0, "access_token" => "tok", "expires_in" => 7200})

        _other ->
          responder.(conn)
      end
    end

    Client.new(
      corp_id: "corp-#{System.unique_integer([:positive])}",
      secret: "s3cret",
      req_options: [plug: plug]
    )
  end

  test "authorize_url builds the WWLogin CorpApp page" do
    url =
      OAuth.authorize_url(
        corp_id: "ww123",
        agentid: "1000002",
        redirect_uri: "https://ankole.example/sessions/oidc/wecom/callback",
        state: "state-1"
      )

    assert String.starts_with?(url, "https://login.work.weixin.qq.com/wwlogin/sso/login?")
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "login_type" => "CorpApp",
             "appid" => "ww123",
             "agentid" => "1000002",
             "redirect_uri" => "https://ankole.example/sessions/oidc/wecom/callback",
             "state" => "state-1",
             "lang" => "zh"
           }
  end

  test "get_user_info returns the member userid" do
    client =
      client(fn conn ->
        assert conn.request_path == "/cgi-bin/auth/getuserinfo"
        assert conn.query_params["code"] == "code-1"
        Req.Test.json(conn, %{"errcode" => 0, "userid" => "alice"})
      end)

    assert {:ok, %{userid: "alice"}} = OAuth.get_user_info(client, "code-1")
  end

  test "non-members and linked-corp members fail closed" do
    openid_client =
      client(fn conn -> Req.Test.json(conn, %{"errcode" => 0, "openid" => "o-123"}) end)

    assert {:error, :non_member} = OAuth.get_user_info(openid_client, "code-1")

    linked_client =
      client(fn conn -> Req.Test.json(conn, %{"errcode" => 0, "userid" => "CorpX/bob"}) end)

    assert {:error, :non_member} = OAuth.get_user_info(linked_client, "code-1")
  end

  test "invalid codes classify as :invalid_code" do
    client =
      client(fn conn ->
        Req.Test.json(conn, %{"errcode" => 40_029, "errmsg" => "invalid code"})
      end)

    assert {:error, %Error{reason: :invalid_code}} = OAuth.get_user_info(client, "expired")
  end
end
