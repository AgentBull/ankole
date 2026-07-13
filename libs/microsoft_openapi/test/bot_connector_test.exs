defmodule MicrosoftOpenAPI.BotConnectorTest do
  use ExUnit.Case, async: true

  alias MicrosoftOpenAPI.BotConnector
  alias MicrosoftOpenAPI.BotOpenID
  alias MicrosoftOpenAPI.Client
  alias MicrosoftOpenAPI.Error

  @service_url "https://smba.microsoft.test/teams/"

  defp client(overrides \\ []) do
    Client.new(
      Keyword.merge(
        [
          tenant_id: "bot-tenant-#{System.unique_integer([:positive])}",
          client_id: "app-1",
          client_secret: "password-1",
          login_base_url: "https://login.microsoft.test",
          req_options: [plug: {Req.Test, __MODULE__}]
        ],
        overrides
      )
    )
  end

  defp stub_with_token(handler) do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)
        assert form["scope"] == "https://api.botframework.com/.default"
        Req.Test.json(conn, %{"access_token" => "bot-token", "expires_in" => 3600})
      else
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bot-token"]
        handler.(conn)
      end
    end)
  end

  test "bot token tenant prefers the multi-tenant override" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:token_path, conn.request_path})
      Req.Test.json(conn, %{"access_token" => "bot-token", "expires_in" => 3600})
    end)

    client = client(bot_token_tenant: "botframework.com")
    assert {:ok, "bot-token"} = BotConnector.token(client)
    assert_received {:token_path, "/botframework.com/oauth2/v2.0/token"}
  end

  test "post_activity targets the conversation activities collection" do
    stub_with_token(fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/teams/v3/conversations/19%3Achannel%40thread.tacv2%3Bmessageid%3D42/activities"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"type" => "message", "text" => "hello"} = Torque.decode!(body)
      Req.Test.json(conn, %{"id" => "activity-1"})
    end)

    assert {:ok, %{"id" => "activity-1"}} =
             BotConnector.post_activity(
               client(),
               @service_url,
               "19:channel@thread.tacv2;messageid=42",
               %{"type" => "message", "text" => "hello"}
             )
  end

  test "update and delete address one activity" do
    stub_with_token(fn conn ->
      case conn.method do
        "PUT" ->
          assert conn.request_path == "/teams/v3/conversations/conv-1/activities/act-1"
          Req.Test.json(conn, %{"id" => "act-1"})

        "DELETE" ->
          assert conn.request_path == "/teams/v3/conversations/conv-1/activities/act-2"
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    assert {:ok, %{"id" => "act-1"}} =
             BotConnector.update_activity(client(), @service_url, "conv-1", "act-1", %{
               "type" => "message",
               "text" => "edited"
             })

    assert {:ok, %{}} = BotConnector.delete_activity(client(), @service_url, "conv-1", "act-2")
  end

  test "create_conversation posts to the conversations collection" do
    stub_with_token(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/teams/v3/conversations"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"isGroup" => true} = Torque.decode!(body)
      Req.Test.json(conn, %{"id" => "19:channel@thread.tacv2;messageid=77"})
    end)

    assert {:ok, %{"id" => "19:channel@thread.tacv2;messageid=77"}} =
             BotConnector.create_conversation(client(), @service_url, %{
               "isGroup" => true,
               "channelData" => %{"channel" => %{"id" => "19:channel@thread.tacv2"}},
               "activity" => %{"type" => "message", "text" => "new thread"}
             })
  end

  test "list_team_channels and paged members stream with continuation" do
    stub_with_token(fn conn ->
      case conn.request_path do
        "/teams/v3/teams/team-1/conversations" ->
          Req.Test.json(conn, %{"conversations" => [%{"id" => "19:general@thread.tacv2"}]})

        "/teams/v3/conversations/conv-1/pagedmembers" ->
          case URI.decode_query(conn.query_string) do
            %{"continuationToken" => "next-1"} ->
              Req.Test.json(conn, %{"members" => [%{"id" => "29:b", "aadObjectId" => "oid-b"}]})

            _first_page ->
              Req.Test.json(conn, %{
                "continuationToken" => "next-1",
                "members" => [%{"id" => "29:a", "aadObjectId" => "oid-a"}]
              })
          end
      end
    end)

    assert {:ok, %{"conversations" => [_general]}} =
             BotConnector.list_team_channels(client(), @service_url, "team-1")

    members =
      BotConnector.stream_paged_members(client(), @service_url, "conv-1") |> Enum.to_list()

    assert [{:ok, %{"aadObjectId" => "oid-a"}}, {:ok, %{"aadObjectId" => "oid-b"}}] = members
  end

  test "connector errors surface the provider error code" do
    stub_with_token(fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"error" => %{"code" => "ConversationBlockedByUser"}})
    end)

    assert {:error, %Error{reason: "ConversationBlockedByUser", status: 403}} =
             BotConnector.post_activity(client(), @service_url, "conv-1", %{"type" => "message"})
  end

  test "bot openid metadata resolves signing keys by kid and caches them" do
    metadata_url = "https://login.bot.test/v1/.well-known/openidconfiguration-#{System.unique_integer([:positive])}"
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:fetch, conn.request_path})

      case conn.request_path do
        "/v1/.well-known/keys" ->
          Req.Test.json(conn, %{
            "keys" => [
              %{"kty" => "RSA", "kid" => "key-1", "n" => "n-1", "e" => "AQAB"},
              %{"kty" => "RSA", "kid" => "key-2", "n" => "n-2", "e" => "AQAB"}
            ]
          })

        "/v1/.well-known/openidconfiguration-" <> _unique ->
          Req.Test.json(conn, %{
            "issuer" => "https://api.botframework.com",
            "jwks_uri" => "https://login.bot.test/v1/.well-known/keys"
          })
      end
    end)

    opts = [metadata_url: metadata_url, req_options: [plug: {Req.Test, __MODULE__}]]

    assert {:ok, %{"kid" => "key-1", "n" => "n-1"}} = BotOpenID.signing_jwk("key-1", opts)
    assert {:ok, %{"kid" => "key-2"}} = BotOpenID.signing_jwk("key-2", opts)
    assert {:error, :unknown_kid} = BotOpenID.signing_jwk("key-3", opts)

    assert_received {:fetch, _metadata}
    assert_received {:fetch, "/v1/.well-known/keys"}
    # Second and third lookups are served from cache; the unknown kid is within
    # the refetch backoff so no extra fetch happens.
    refute_received {:fetch, _any}
  end
end
