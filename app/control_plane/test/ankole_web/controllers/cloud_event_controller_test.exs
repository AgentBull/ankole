defmodule AnkoleWeb.CloudEventControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Signals.{Bindings, Signal, Webhooks}
  alias Ankole.Repo

  test "real HTTP ingress uses endpoint authentication and the only Signal intake" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    assert {:ok, endpoint} =
             Webhooks.create_endpoint(%{
               label: "Issue changes",
               mode: "standing",
               event_format: "cloudevents",
               expires_at: DateTime.add(now, 1, :hour)
             })

    assert {:ok, _} =
             Bindings.put_binding(agent.uid, "cloudevents", "issues", %{
               "config" => %{"webhook_endpoint_id" => endpoint.webhook_endpoint.id},
               "target" => %{"session_id" => "issues"}
             })

    path = "/signals/v1/cloudevents/#{endpoint.token}"

    body =
      Ankole.JSON.encode!(%{
        "specversion" => "1.0",
        "source" => "https://example.com/issues",
        "id" => "issue-one",
        "type" => "issue.changed",
        "data" => [1, false]
      })

    conn =
      build_conn()
      |> put_req_header("content-type", "application/cloudevents+json")
      |> post(path, body)

    assert %{"status" => "accepted", "signal_ids" => [id]} = json_response(conn, 202)
    assert Repo.with_tenant(agent.tenant_id, fn -> Repo.get!(Signal, id).data end) == [1, false]

    assert {:info, log} = AnkoleWeb.RequestLogger.build_log(%{duration: 0}, %{conn: conn})
    assert log.http_request["requestURL"] =~ "/signals/v1/cloudevents/[REDACTED]"
    refute Ankole.JSON.encode!(log) =~ endpoint.token

    conn =
      build_conn()
      |> put_req_header("content-type", "application/cloudevents+json")
      |> post(path, body)

    assert json_response(conn, 202)["signal_ids"] == [id]
    assert Repo.with_tenant(agent.tenant_id, fn -> Repo.aggregate(Signal, :count) end) == 1

    conn = build_conn() |> put_req_header("content-type", "application/json") |> post(path, body)
    assert json_response(conn, 415)["error"]["code"] == "structured_cloudevents_json_required"

    conn =
      build_conn()
      |> put_req_header("content-type", "application/cloudevents+json")
      |> post(path, "{")

    assert json_response(conn, 400)["error"]["code"] == "invalid_json"

    conn =
      build_conn()
      |> put_req_header("content-type", "application/cloudevents+json")
      |> post(path <> "x", body)

    assert response(conn, 404) == ""
    assert Repo.with_tenant(agent.tenant_id, fn -> Repo.aggregate(Signal, :count) end) == 1
  end
end
