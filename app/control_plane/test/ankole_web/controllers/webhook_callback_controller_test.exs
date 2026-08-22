defmodule AnkoleWeb.WebhookCallbackControllerTest do
  use AnkoleWeb.ConnCase, async: true

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Webhooks
  alias AnkoleWeb.Plugs.WebhookCallbackBodyReader

  @now ~U[2026-07-30 01:00:00.000000Z]
  @token "wh_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"

  test "callback route accepts an opaque body without browser authentication", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)

    assert {:ok, %{webhook_endpoint: _endpoint}} =
             Webhooks.create_endpoint(
               %{
                 agent_uid: agent.uid,
                 binding_name: source.binding_name,
                 session_id: source.session_id,
                 signal_channel_id: source.signal_channel_id,
                 provider_thread_id: source.provider_thread_id,
                 source_actor_event_id: source.id,
                 source_entry_id: source.source_entry_id,
                 source_provenance: %{},
                 label: "GitHub pull requests",
                 mode: "standing",
                 expires_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :hour)
               },
               @token
             )

    conn =
      conn
      |> put_req_header("content-type", "application/vnd.github+json")
      |> put_req_header("x-github-event", "pull_request")
      |> post("/webhooks/v1/event-callbacks/#{@token}", ~s({"action":"opened"}))

    assert response(conn, 204) == ""

    assert %ActorEvent{} =
             Repo.one(from(event in ActorEvent, where: event.type == "webhook.received"))
  end

  test "callback route returns 404 for an unknown credential", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/webhooks/v1/event-callbacks/#{@token}", "unknown")

    assert response(conn, 404) == ""
  end

  test "legacy callback route is not exposed", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/cb/#{@token}", "")

    assert conn.status == 404
  end

  test "callback route rejects a body above the declared limit", %{conn: conn} do
    body = String.duplicate("x", WebhookCallbackBodyReader.max_body_bytes() + 1)

    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/webhooks/v1/event-callbacks/#{@token}", body)

    assert response(conn, 413) == ""
  end

  defp source_event!(agent_uid) do
    assert {:ok, event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent_uid,
               binding_name: "github",
               session_id: "callback-controller",
               source_event_id: "callback-controller-source",
               signal_channel_id: "lark:chat:callback",
               provider_thread_id: "thread-callback",
               source_entry_id: "message-callback",
               type: "im.message.addressed",
               available_at: @now,
               sender_key: nil,
               payload: %{
                 "specversion" => "1.0",
                 "id" => "callback-controller-source",
                 "source" => "test://webhooks",
                 "type" => "im.message.addressed",
                 "data" => %{}
               }
             })

    event
  end
end
