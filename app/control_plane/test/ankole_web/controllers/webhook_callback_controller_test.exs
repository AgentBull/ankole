defmodule AnkoleWeb.WebhookCallbackControllerTest do
  use AnkoleWeb.ConnCase, async: true

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.Repo

  alias Ankole.Signals.Signal
  alias Ankole.Signals.Webhooks
  alias AnkoleWeb.Plugs.WebhookCallbackBodyReader

  @token "wh_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"

  test "callback route accepts an opaque body without browser authentication", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)

    assert {:ok, %{webhook_endpoint: _endpoint, token: token}} =
             Webhooks.create_endpoint(%{
               agent_uid: agent.uid,
               binding_name: source.reply_binding_name,
               session_id: source.session_id,
               conversation_id: source.conversation_id,
               provider_thread_id: source.provider_thread_id,
               source_signal_id: source.id,
               provider_message_id: source.provider_message_id,
               source_provenance: %{},
               label: "GitHub pull requests",
               mode: "standing",
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :hour)
             })

    conn =
      conn
      |> put_req_header("content-type", "application/vnd.github+json")
      |> put_req_header("x-github-event", "pull_request")
      |> post("/webhooks/v1/event-callbacks/#{token}", ~s({"action":"opened"}))

    assert response(conn, 204) == ""

    assert %Signal{} =
             Repo.with_tenant(agent.tenant_id, fn ->
               Repo.one(from(event in Signal, where: event.type == "webhook.received"))
             end)
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
    Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid,
      binding_name: "github",
      source: "test://webhook-source"
    )
  end
end
