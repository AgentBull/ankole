defmodule DingTalkOpenAPI.RobotTest do
  # async: false — these tests seed and clear a shared-ETS app token.
  use ExUnit.Case, async: false

  alias DingTalkOpenAPI.{Client, Robot}

  setup do
    client =
      Client.new(
        client_id: "ding-app",
        client_secret: "secret",
        api_base_url: "https://api.dingtalk.test",
        oapi_base_url: "https://oapi.dingtalk.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    seed_app_token(client, "atok")
    %{client: client}
  end

  test "send_group_message encodes msg_param as a JSON string and returns the processQueryKey", %{
    client: client
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/robot/groupMessages/send"
      assert Plug.Conn.get_req_header(conn, "x-acs-dingtalk-access-token") == ["atok"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Torque.decode!(body)
      assert decoded["openConversationId"] == "cid"
      assert decoded["robotCode"] == "ding-app"
      assert decoded["msgKey"] == "sampleMarkdown"
      # msgParam is a stringified JSON object on the wire.
      assert Torque.decode!(decoded["msgParam"]) == %{"title" => "t", "text" => "hello"}
      Req.Test.json(conn, %{"processQueryKey" => "pqk-1"})
    end)

    assert {:ok, %{"processQueryKey" => "pqk-1"}} =
             Robot.send_group_message(client,
               open_conversation_id: "cid",
               robot_code: "ding-app",
               msg_key: "sampleMarkdown",
               msg_param: %{"title" => "t", "text" => "hello"}
             )
  end

  test "batch_send_oto sends the userIds list", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/robot/oToMessages/batchSend"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Torque.decode!(body)
      assert decoded["userIds"] == ["staff-1"]
      Req.Test.json(conn, %{"processQueryKey" => "pqk-2", "flowControlledStaffIdList" => []})
    end)

    assert {:ok, %{"processQueryKey" => "pqk-2"}} =
             Robot.batch_send_oto(client,
               robot_code: "ding-app",
               user_ids: ["staff-1"],
               msg_key: "sampleText",
               msg_param: %{"content" => "hi"}
             )
  end

  test "recall_group sends the processQueryKeys", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/robot/groupMessages/recall"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Torque.decode!(body)["processQueryKeys"] == ["pqk-1"]
      Req.Test.json(conn, %{"successResult" => ["pqk-1"]})
    end)

    assert {:ok, _} =
             Robot.recall_group(client,
               open_conversation_id: "cid",
               robot_code: "ding-app",
               process_query_keys: ["pqk-1"]
             )
  end

  test "upload_media posts multipart to the old domain and returns the media_id", %{
    client: client
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "oapi.dingtalk.test"
      assert conn.request_path == "/media/upload"
      assert URI.decode_query(conn.query_string)["type"] == "image"
      assert ["multipart/form-data" <> _] = Plug.Conn.get_req_header(conn, "content-type")
      Req.Test.json(conn, %{"errcode" => 0, "media_id" => "@media-1"})
    end)

    assert {:ok, "@media-1"} = Robot.upload_media(client, "image", "BYTES", "pic.png")
  end

  test "download_message_file resolves the code then pulls bytes without exposing the temp url",
       %{
         client: client
       } do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v1.0/robot/messageFiles/download" ->
          Req.Test.json(conn, %{"downloadUrl" => "https://files.dingtalk.test/tmp?sig=abc"})

        "/tmp" ->
          Plug.Conn.send_resp(conn, 200, "FILEBYTES")
      end
    end)

    assert {:ok, %{body: "FILEBYTES"}} =
             Robot.download_message_file(client, "ding-app", "dl-code")
  end

  defp seed_app_token(client, token) do
    key = {:app, Client.cache_namespace(client)}
    expires_at = System.monotonic_time(:millisecond) + :timer.hours(1)
    :ets.insert(DingTalkOpenAPI.TokenStore.table(), {key, token, expires_at})

    on_exit(fn -> :ets.delete(DingTalkOpenAPI.TokenStore.table(), key) end)
  end
end
