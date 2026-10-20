defmodule AnkoleWeb.CloudEventEndpointControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import OpenApiSpex.TestAssertions

  alias Ankole.AppConfigure.{Cache, Registry}
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.Signals.{Binding, Signal, Webhooks}
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
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
    spec = AnkoleWeb.APISpec.spec()
    conn = console_conn(conn)

    catalog = conn |> get(~p"/api/v1/signal-adapters") |> json_response(200)
    assert_schema(catalog, "SignalAdapterListResponse", spec)
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
      |> recycle_api()
      |> post(~p"/api/v1/webhook-endpoints", %{
        "label" => "Issue events",
        "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :hour))
      })
      |> json_response(201)

    assert_schema(created, "CloudEventEndpointCreateResponse", spec)

    assert %{
             "webhook_endpoint" => %{"id" => id, "event_format" => "cloudevents"},
             "token" => token
           } = created

    assert is_nil(created["webhook_endpoint"]["agent_uid"])

    saved =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/cloudevents/issues", %{
        "config" => %{
          "webhook_endpoint_id" => id,
          "target_kind" => "session",
          "target_id" => "issue-triage",
          "filter_cel" => "signal.type == 'issue.changed'"
        }
      })
      |> json_response(200)

    assert_schema(saved, "SignalBindingResponse", spec)
    assert saved["signal_binding"]["target"] == %{"session_id" => "issue-triage"}
    assert Repo.get_by!(Binding, agent_uid: agent.uid, name: "issues").adapter == "cloudevents"

    listed = conn |> recycle_api() |> get(~p"/api/v1/webhook-endpoints") |> json_response(200)
    assert_schema(listed, "WebhookEndpointListResponse", spec)
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
      conn |> recycle_api() |> delete(~p"/api/v1/webhook-endpoints/#{id}") |> json_response(200)

    assert_schema(cancelled, "WebhookEndpointResponse", spec)
    assert cancelled["webhook_endpoint"]["status"] == "cancelled"

    assert {:ok, %{status: :ignored}} =
             Webhooks.receive_cloudevent(token, %{event | "id" => "changed-2"})

    assert Repo.with_tenant(agent.tenant_id, fn -> Repo.aggregate(Signal, :count) end) == 1
  end

  test "operator configures a fixed route independently of event subjects", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    created =
      conn
      |> post(~p"/api/v1/webhook-endpoints", %{
        "label" => "Fixed issue events",
        "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :hour))
      })
      |> json_response(201)

    saved =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/cloudevents/issues", %{
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
    assert conn |> post(~p"/api/v1/webhook-endpoints", %{}) |> json_response(401)

    conn = console_conn(conn)

    assert conn
           |> post(~p"/api/v1/webhook-endpoints", %{"label" => "Events"})
           |> json_response(422)

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/webhook-endpoints", %{
             "label" => "Events",
             "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1, :second))
           })
           |> json_response(422)

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/webhook-endpoints", %{
             "label" => "Events" <> <<0>>,
             "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :hour))
           })
           |> json_response(422)

    assert Webhooks.list_endpoints(nil, nil) == []
  end
end
