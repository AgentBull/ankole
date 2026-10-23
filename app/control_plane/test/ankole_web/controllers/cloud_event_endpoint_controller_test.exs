defmodule AnkoleWeb.CloudEventEndpointControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.{Cache, Registry}
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.Signals.{Binding, Signal, Webhooks}
  alias Ankole.Repo

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "operator creates a source endpoint, subscribes an Agent, and cancels the credential",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    catalog = conn |> json_api(:get, "/api/v2/signal-adapters") |> json_response(200)

    source = Enum.find(catalog["signal_adapters"], &(&1["adapter_id"] == "cloudevents"))
    assert source["adapter_category"] == "event_source"
    assert is_nil(source["group_message_mode_field"])
    assert is_nil(source["unmatched_sender_policy_field"])

    target_kind = Enum.find(source["fields"], &(&1["path"] == "target_kind"))

    assert Enum.map(target_kind["options"], & &1["value"]) == [
             "conversation",
             "session"
           ]

    assert Enum.find(source["fields"], &(&1["path"] == "target_id"))["required"]

    created =
      conn
      |> json_api(:post, "/api/v2/webhook-endpoints", %{
        "label" => "Issue events",
        "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :hour))
      })
      |> json_response(201)

    assert %{
             "webhook_endpoint" => %{"id" => id, "event_format" => "cloudevents"},
             "token" => token
           } = created

    assert is_nil(created["webhook_endpoint"]["agent_uid"])

    saved =
      conn
      |> recycle_api()
      |> json_api(:put, "/api/v2/agents/#{agent.uid}/signal-bindings/cloudevents/issues", %{
        "config" => %{
          "webhook_endpoint_id" => id,
          "target_kind" => "session",
          "target_id" => "issue-triage",
          "filter_cel" => "signal.type == 'issue.changed'"
        }
      })
      |> json_response(200)

    assert saved["signal_binding"]["target"] == %{"session_id" => "issue-triage"}
    assert Repo.get_by!(Binding, agent_uid: agent.uid, name: "issues").adapter == "cloudevents"

    listed = conn |> json_api(:get, "/api/v2/webhook-endpoints") |> json_response(200)
    assert [%{"id" => ^id}] = listed["data"]
    refute inspect(listed) =~ token
    refute inspect(listed) =~ Webhooks.token_digest(token)

    event = %{
      "specversion" => "1.0",
      "source" => "https://issues.example.com",
      "id" => "changed-1",
      "type" => "issue.changed",
      "data" => %{"issue" => 7}
    }

    assert {:ok, %{signals: [%Signal{session_id: "issue-triage"}]}} =
             Webhooks.receive_cloudevent(token, event)

    cancelled =
      conn |> json_api(:delete, "/api/v2/webhook-endpoints/#{id}") |> json_response(200)

    assert cancelled["status"] == "cancelled"

    assert {:ok, %{status: :ignored}} =
             Webhooks.receive_cloudevent(token, %{event | "id" => "changed-2"})

    assert Repo.with_tenant(agent.tenant_id, fn -> Repo.aggregate(Signal, :count) end) == 1
  end

  test "operator configures a fixed route independently of event subjects", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    created =
      conn
      |> json_api(:post, "/api/v2/webhook-endpoints", %{
        "label" => "Fixed issue events",
        "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :hour))
      })
      |> json_response(201)

    saved =
      conn
      |> recycle_api()
      |> json_api(:put, "/api/v2/agents/#{agent.uid}/signal-bindings/cloudevents/issues", %{
        "config" => %{
          "webhook_endpoint_id" => created["webhook_endpoint"]["id"],
          "target_kind" => "session",
          "target_id" => "issue-triage"
        }
      })
      |> json_response(200)

    assert saved["signal_binding"]["target"] == %{"session_id" => "issue-triage"}

    event = %{
      "specversion" => "1.0",
      "source" => "https://issues.example.com",
      "subject" => "issue/7",
      "id" => "changed-1",
      "type" => "issue.changed"
    }

    assert {:ok, %{signals: [first]}} = Webhooks.receive_cloudevent(created["token"], event)

    assert {:ok, %{signals: [second]}} =
             Webhooks.receive_cloudevent(created["token"], %{
               event
               | "id" => "changed-2",
                 "subject" => "issue/8"
             })

    assert first.session_id == "issue-triage"
    assert second.session_id == "issue-triage"
    assert first.id != second.id
  end

  test "endpoint creation needs an authenticated operator and explicit future expiry", %{
    conn: conn
  } do
    assert conn |> post("/api/v2/webhook-endpoints", %{}) |> json_response(401)

    conn = console_conn(conn)

    assert conn
           |> json_api(:post, "/api/v2/webhook-endpoints", %{"label" => "Events"})
           |> json_response(400)

    assert %{"errors" => [%{"code" => "webhook_expiry_must_be_future"}]} =
             conn
             |> json_api(:post, "/api/v2/webhook-endpoints", %{
               "label" => "Events",
               "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1, :second))
             })
             |> json_response(422)

    assert conn
           |> json_api(:post, "/api/v2/webhook-endpoints", %{
             "label" => "Events" <> <<0>>,
             "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :hour))
           })
           |> json_response(400)

    assert Webhooks.list_endpoints(nil, nil) == []
  end

  defp json_api(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> dispatch(@endpoint, method, path, if(data, do: Jason.encode!(%{data: data}), else: ""))
  end
end
