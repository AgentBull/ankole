defmodule SlackOpenAPITest do
  use ExUnit.Case, async: true

  alias SlackOpenAPI.{Client, Error, Pagination}

  setup do
    client =
      Client.new(
        bot_token: "xoxb-test",
        app_token: "xapp-test",
        base_url: "https://slack.test/api",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    %{client: client}
  end

  test "client redacts tokens and resolves closures", %{client: client} do
    assert Client.bot_token(client) == "xoxb-test"
    assert Client.app_token(client) == "xapp-test"
    refute inspect(client) =~ "xoxb-test"
    refute inspect(client) =~ "xapp-test"
  end

  test "JSON request sends bot bearer token and normalizes success", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/chat.postMessage"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-test"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Torque.decode!(body) == %{"channel" => "C1", "text" => "hello"}
      Req.Test.json(conn, %{"ok" => true, "channel" => "C1", "ts" => "1.1"})
    end)

    assert {:ok, %{"ts" => "1.1"}} =
             SlackOpenAPI.post(client, "chat.postMessage",
               body: %{"channel" => "C1", "text" => "hello"}
             )
  end

  test "numeric mock-server timestamps are normalized to Slack string identifiers", %{
    client: client
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"ok" => true, "channel" => "C1", "ts" => 1_610_241_741.0002})
    end)

    assert {:ok, %{"ts" => "1610241741.0002"}} =
             SlackOpenAPI.post(client, "chat.postMessage",
               body: %{"channel" => "C1", "text" => "hello"}
             )
  end

  test "app token and Slack body errors are normalized", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xapp-test"]
      Req.Test.json(conn, %{"ok" => false, "error" => "invalid_auth"})
    end)

    assert {:error, %Error{reason: "invalid_auth"}} =
             SlackOpenAPI.post(client, "apps.connections.open", token: :app, body: %{})
  end

  test "429 preserves Retry-After", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "7")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"ok" => false, "error" => "ratelimited"})
    end)

    assert {:error, %Error{reason: :rate_limited, retry_after: 7}} =
             SlackOpenAPI.get(client, "users.list")
  end

  test "cursor pagination traverses pages", %{client: client} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      page = Agent.get_and_update(counter, &{&1, &1 + 1})
      params = URI.decode_query(conn.query_string)

      case page do
        0 ->
          assert params == %{"limit" => "2"}

          Req.Test.json(conn, %{
            "ok" => true,
            "members" => [%{"id" => "U1"}],
            "response_metadata" => %{"next_cursor" => "next"}
          })

        1 ->
          assert params == %{"cursor" => "next", "limit" => "2"}

          Req.Test.json(conn, %{
            "ok" => true,
            "members" => [%{"id" => "U2"}],
            "response_metadata" => %{"next_cursor" => ""}
          })
      end
    end)

    assert [{:ok, %{"id" => "U1"}}, {:ok, %{"id" => "U2"}}] =
             Pagination.stream(client, "users.list", query: [limit: 2], items: ["members"])
             |> Enum.to_list()
  end
end
