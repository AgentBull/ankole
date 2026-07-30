defmodule WeComOpenAPITest do
  use ExUnit.Case, async: true

  alias WeComOpenAPI.Corp.Client
  alias WeComOpenAPI.Error

  defp client(plug, opts \\ []) do
    Client.new(
      Keyword.merge(
        [
          corp_id: "corp-#{System.unique_integer([:positive])}",
          secret: "s3cret",
          req_options: [plug: plug]
        ],
        opts
      )
    )
  end

  defp token_plug(responder) do
    fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/cgi-bin/gettoken" ->
          assert conn.query_params["corpsecret"] == "s3cret"
          Req.Test.json(conn, %{"errcode" => 0, "access_token" => "tok-1", "expires_in" => 7200})

        _other ->
          responder.(conn)
      end
    end
  end

  test "injects the cached access token into the query and decodes errcode envelopes" do
    plug =
      token_plug(fn conn ->
        assert conn.request_path == "/cgi-bin/user/get"
        assert conn.query_params["access_token"] == "tok-1"
        assert conn.query_params["userid"] == "alice"
        Req.Test.json(conn, %{"errcode" => 0, "errmsg" => "ok", "userid" => "alice"})
      end)

    assert {:ok, %{"userid" => "alice"}} =
             WeComOpenAPI.get(client(plug), "/cgi-bin/user/get", query: [userid: "alice"])
  end

  test "non-zero errcode surfaces as a classified error" do
    plug =
      token_plug(fn conn ->
        Req.Test.json(conn, %{"errcode" => 60_020, "errmsg" => "not allow to access from your ip"})
      end)

    assert {:error, %Error{reason: :ip_rejected, code: 60_020}} =
             WeComOpenAPI.get(client(plug), "/cgi-bin/department/list")
  end

  test "an auth failure invalidates the token and retries once with a fresh one" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/cgi-bin/gettoken" ->
          send(parent, :token_fetch)

          Req.Test.json(conn, %{
            "errcode" => 0,
            "access_token" => "tok-#{System.unique_integer([:positive])}",
            "expires_in" => 7200
          })

        "/cgi-bin/user/get" ->
          send(parent, {:api_call, conn.query_params["access_token"]})

          case Process.get(:already_failed) do
            nil ->
              Process.put(:already_failed, true)
              Req.Test.json(conn, %{"errcode" => 42_001, "errmsg" => "access_token expired"})

            true ->
              Req.Test.json(conn, %{"errcode" => 0, "userid" => "alice"})
          end
      end
    end

    # Req's plug adapter runs the plug in the caller process, so Process.get
    # keeps the two API calls of one request distinguishable.
    assert {:ok, %{"userid" => "alice"}} =
             WeComOpenAPI.get(client(plug), "/cgi-bin/user/get", query: [userid: "alice"])

    assert_received :token_fetch
    assert_received {:api_call, first_token}
    assert_received :token_fetch
    assert_received {:api_call, second_token}
    assert first_token != second_token
  end

  test "download returns bytes and the content-disposition filename" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="a.png"))
      |> Plug.Conn.send_resp(200, <<1, 2, 3>>)
    end

    assert {:ok, %{body: <<1, 2, 3>>, filename: "a.png"}} =
             WeComOpenAPI.download("https://example.invalid/media", plug: plug)
  end
end
