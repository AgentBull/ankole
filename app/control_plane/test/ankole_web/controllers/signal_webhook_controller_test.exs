defmodule AnkoleWeb.SignalWebhookControllerTest do
  use AnkoleWeb.ConnCase, async: true

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
