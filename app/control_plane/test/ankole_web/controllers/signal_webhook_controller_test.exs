defmodule AnkoleWeb.SignalWebhookControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.Principals.MappingRequests
  alias Ankole.Repo

  alias Ankole.Conversations.{ExternalMessageRef, Message}

  @line_channel_id "1650000777"
  @line_secret "controller-line-secret"
  @line_user "U0000000000000000000000000000777"
  @whatsapp_app_id "1009900000777"
  @whatsapp_verify_token "controller-verify-token"

  test "a signed LINE webhook reaches durable ingress through the raw body", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()

    assert {:ok, _identity} =
             MappingRequests.bind_subject(human.uid, %{provider: "line", external_id: @line_user})

    assert {:ok, _binding} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "line", "line-http", %{
               "config" => %{
                 "channelId" => @line_channel_id,
                 "channelSecret" => @line_secret,
                 "channelAccessToken" => "controller-line-token"
               }
             })

    body =
      Ankole.JSON.encode!(%{
        "destination" => "Ubot0000000000000000000000000000777",
        "events" => [
          %{
            "type" => "message",
            "mode" => "active",
            "timestamp" => 1_787_000_000_000,
            "webhookEventId" => "01LINEHTTP000000000000000001",
            "deliveryContext" => %{"isRedelivery" => false},
            "source" => %{"type" => "user", "userId" => @line_user},
            "message" => %{"id" => "http-m-1", "type" => "text", "text" => "hello"}
          }
        ]
      })

    path = ~p"/webhooks/v1/line/#{@line_channel_id}/events"

    signed =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "x-line-signature",
        Base.encode64(:crypto.mac(:hmac, :sha256, @line_secret, body))
      )
      |> post(path, body)

    assert json_response(signed, 200) == %{}

    assert %Message{text: "hello"} =
             Repo.with_tenant(agent.tenant_id, fn ->
               Repo.one(
                 from message in Message,
                   join: ref in ExternalMessageRef,
                   on: ref.message_id == message.id and ref.tenant_id == message.tenant_id,
                   where: ref.provider_message_id == "http-m-1",
                   select: message
               )
             end)

    tampered =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "x-line-signature",
        Base.encode64(:crypto.mac(:hmac, :sha256, @line_secret, body))
      )
      |> post(path, String.replace(body, "hello", "hacked"))

    assert json_response(tampered, 401) == %{"error" => "unauthorized"}
    assert Repo.with_tenant(agent.tenant_id, fn -> Repo.aggregate(Message, :count) end) == 1
  end

  test "a GET reaches the handler with the subscription query", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _binding} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "whatsapp", "whatsapp-http", %{
               "config" => %{
                 "appId" => @whatsapp_app_id,
                 "appSecret" => "controller-app-secret",
                 "verifyToken" => @whatsapp_verify_token,
                 "phoneNumberId" => "1500000000777",
                 "accessToken" => "controller-access-token"
               },
               "group_message_mode" => "addressed_only"
             })

    path = ~p"/webhooks/v1/whatsapp/#{@whatsapp_app_id}/events"

    verified =
      get(conn, path, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => @whatsapp_verify_token,
        "hub.challenge" => "challenge-777"
      })

    assert response(verified, 200) == "challenge-777"
    assert response_content_type(verified, :text) =~ "text/plain"

    refused =
      get(build_conn(), path, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "wrong-token",
        "hub.challenge" => "challenge-777"
      })

    assert json_response(refused, 403) == %{"error" => "forbidden"}
  end

  test "unknown handlers return 404 without echoing the payload", %{conn: conn} do
    conn =
      post(conn, ~p"/webhooks/v1/unknown-handler/instance-1/messages", %{
        "type" => "message",
        "text" => "attacker-controlled"
      })

    assert json_response(conn, 404) == %{"error" => "unknown webhook"}
    refute conn.resp_body =~ "attacker-controlled"
  end

  test "webhook route skips session and CSRF protection", %{conn: conn} do
    # A cross-origin provider POST carries no CSRF token; reaching the 404
    # branch (instead of an invalid-CSRF error) proves the route sits outside
    # the browser pipelines.
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/v1/unknown-handler/instance-1/messages", "{}")

    assert conn.status == 404
  end
end
