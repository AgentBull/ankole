defmodule AnkoleWeb.SignalWebhookControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Plugins.LineAdapter.Signature
  alias Ankole.Principals.MappingRequests
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Entry

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
             SignalsGateway.put_binding(agent.uid, "line", "line-http", %{
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
      |> put_req_header("x-line-signature", Signature.sign(body, @line_secret))
      |> post(path, body)

    assert json_response(signed, 200) == %{}
    assert %Entry{text: "hello"} = Repo.get_by(Entry, source_entry_id: "http-m-1")

    tampered =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-line-signature", Signature.sign(body, @line_secret))
      |> post(path, String.replace(body, "hello", "hacked"))

    assert json_response(tampered, 401) == %{"error" => "unauthorized"}
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "a GET reaches the handler with the subscription query", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _binding} =
             SignalsGateway.put_binding(agent.uid, "whatsapp", "whatsapp-http", %{
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
