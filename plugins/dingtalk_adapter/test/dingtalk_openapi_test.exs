defmodule DingTalkOpenAPITest do
  use ExUnit.Case, async: true

  alias DingTalkOpenAPI.{Client, Error}

  setup do
    client =
      Client.new(
        client_id: "ding-app",
        client_secret: "secret",
        api_base_url: "https://api.dingtalk.test",
        oapi_base_url: "https://oapi.dingtalk.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    %{client: client}
  end

  test "client resolves the secret closure but redacts it from inspect", %{client: client} do
    assert Client.client_secret(client) == "secret"
    refute inspect(client) =~ "secret"
  end

  test "new-domain request injects the token header and JSON body", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "api.dingtalk.test"
      assert conn.request_path == "/v1.0/robot/groupMessages/send"
      assert Plug.Conn.get_req_header(conn, "x-acs-dingtalk-access-token") == ["utok"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Torque.decode!(body) == %{"openConversationId" => "cid"}
      Req.Test.json(conn, %{"processQueryKey" => "pqk"})
    end)

    assert {:ok, %{"processQueryKey" => "pqk"}} =
             DingTalkOpenAPI.post(client, "/v1.0/robot/groupMessages/send",
               body: %{"openConversationId" => "cid"},
               token: {:user, "utok"}
             )
  end

  test "old-domain request routes to oapi host and injects access_token query", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "oapi.dingtalk.test"
      assert conn.request_path == "/topapi/v2/user/get"
      assert URI.decode_query(conn.query_string)["access_token"] == "atok"
      Req.Test.json(conn, %{"errcode" => 0, "result" => %{"userid" => "u1"}})
    end)

    assert {:ok, %{"result" => %{"userid" => "u1"}}} =
             DingTalkOpenAPI.post(client, "topapi/v2/user/get",
               body: %{"userid" => "u1"},
               token: {:user, "atok"}
             )
  end

  test "media/ paths route to the old domain", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "oapi.dingtalk.test"
      assert conn.request_path == "/media/upload"
      Req.Test.json(conn, %{"errcode" => 0, "media_id" => "@media"})
    end)

    assert {:ok, %{"media_id" => "@media"}} =
             DingTalkOpenAPI.post(client, "media/upload", token: {:user, "atok"})
  end

  describe "new-domain error classification" do
    for {code, reason} <- [
          {"invalidParameter.token.invalid", :auth},
          {"param.contentUnsafe", :content_rejected},
          {"group.disbanded", :target_gone},
          {"bot.stopped", :target_gone}
        ] do
      test "#{code} → #{reason}", %{client: client} do
        code = unquote(code)
        reason = unquote(reason)

        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"code" => code, "message" => "boom"})
        end)

        assert {:error, %Error{reason: ^reason, code: ^code, message: "boom"}} =
                 DingTalkOpenAPI.post(client, "/v1.0/card/instances",
                   body: %{},
                   token: {:user, "t"}
                 )
      end
    end

    test "unknown new-domain codes keep their raw string", %{client: client} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"code" => "some.novel.code", "message" => "?"})
      end)

      assert {:error, %Error{reason: "some.novel.code"}} =
               DingTalkOpenAPI.post(client, "/v1.0/card/instances",
                 body: %{},
                 token: {:user, "t"}
               )
    end

    test "HTTP 429 is rate limited with Retry-After", %{client: client} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "5")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"code" => "requestOverLimit.qps"})
      end)

      assert {:error, %Error{reason: :rate_limited, retry_after: 5}} =
               DingTalkOpenAPI.get(client, "/v1.0/card/instances", token: {:user, "t"})
    end
  end

  describe "old-domain error classification" do
    for {errcode, reason} <- [
          {20_001, :quota_exhausted},
          {90_018, :rate_limited},
          {60_121, :not_found}
        ] do
      test "errcode #{errcode} → #{reason}", %{client: client} do
        errcode = unquote(errcode)
        reason = unquote(reason)

        Req.Test.stub(__MODULE__, fn conn ->
          Req.Test.json(conn, %{"errcode" => errcode, "errmsg" => "boom"})
        end)

        assert {:error, %Error{reason: ^reason, code: ^errcode}} =
                 DingTalkOpenAPI.post(client, "topapi/v2/user/get",
                   body: %{},
                   token: {:user, "t"}
                 )
      end
    end
  end

  test "download pulls raw bytes and a filename", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=\"report.pdf\"")
      |> Plug.Conn.send_resp(200, "PDFBYTES")
    end)

    assert {:ok, %{body: "PDFBYTES", filename: "report.pdf"}} =
             DingTalkOpenAPI.download(client, "https://files.dingtalk.test/x")
  end
end
