defmodule AnkoleWeb.WebhookEndpointControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import OpenApiSpex.TestAssertions

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Webhooks
  alias AnkoleWeb.Session, as: WebSession

  @token "wh_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
  @other_token "wh_ABCDEFGhijklmnopqrstuvwxyz0123456789abcdefg"

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin lists every session endpoint of one agent and cancels without exposing its capability",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    first = source_event!(agent.uid)
    second = source_event!(agent.uid)

    endpoint = create_endpoint!(agent.uid, first, "Watch GitHub issues", @token)
    other_session_endpoint = create_endpoint!(agent.uid, second, "Watch releases", @other_token)

    api_spec = AnkoleWeb.APISpec.spec()
    conn = bearer_conn(conn)

    list =
      conn
      |> get(~p"/api/v1/agents/#{agent.uid}/webhook-endpoints")
      |> json_response(200)

    assert_schema(list, "WebhookEndpointListResponse", api_spec)
    assert %{"webhook_endpoints" => endpoints} = list

    assert MapSet.new(endpoints, & &1["id"]) ==
             MapSet.new([endpoint.id, other_session_endpoint.id])

    assert MapSet.new(endpoints, & &1["session_id"]) ==
             MapSet.new([first.session_id, second.session_id])

    assert Enum.all?(endpoints, &(&1["status"] == "active"))
    refute inspect(list) =~ @token
    refute inspect(list) =~ Webhooks.token_digest(@token)

    assert conn
           |> recycle_bearer()
           |> delete(~p"/api/v1/agents/#{other_agent.uid}/webhook-endpoints/#{endpoint.id}")
           |> json_response(404)

    cancelled =
      conn
      |> recycle_bearer()
      |> delete(~p"/api/v1/agents/#{agent.uid}/webhook-endpoints/#{endpoint.id}")
      |> json_response(200)

    assert_schema(cancelled, "WebhookEndpointResponse", api_spec)
    assert get_in(cancelled, ["webhook_endpoint", "status"]) == "cancelled"
  end

  test "missing bearer token is rejected", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert conn
           |> get(~p"/api/v1/agents/#{agent.uid}/webhook-endpoints")
           |> json_response(401)
  end

  defp create_endpoint!(agent_uid, source, label, token) do
    assert {:ok, %{webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(
               %{
                 agent_uid: agent_uid,
                 binding_name: source.binding_name,
                 session_id: source.session_id,
                 signal_channel_id: source.signal_channel_id,
                 provider_thread_id: source.provider_thread_id,
                 source_actor_event_id: source.id,
                 source_entry_id: source.source_entry_id,
                 source_provenance: %{"kind" => "console-test"},
                 label: label,
                 mode: "standing",
                 expires_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
               },
               token
             )

    endpoint
  end

  defp source_event!(agent_uid) do
    unique = System.unique_integer([:positive])

    {:ok, event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        binding_name: "github",
        session_id: "conversation-#{unique}",
        source_event_id: "source-#{unique}",
        signal_channel_id: "github:repo:ankole-#{unique}",
        provider_thread_id: "issue:42",
        source_entry_id: "comment:7",
        type: "im.message.addressed",
        available_at: DateTime.utc_now(:microsecond),
        sender_key: nil,
        payload: %{
          "specversion" => "1.0",
          "id" => "source-#{unique}",
          "source" => "test://webhook-console",
          "type" => "im.message.addressed",
          "data" => %{}
        }
      })

    event
  end

  defp bearer_conn(conn) do
    conn
    |> active_admin_conn()
    |> post(~p"/.internal-apis/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
  end

  defp recycle_bearer(conn) do
    authorization = get_req_header(conn, "authorization") |> List.first()

    conn
    |> recycle()
    |> put_req_header("authorization", authorization)
    |> put_req_header("content-type", "application/json")
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("webhook-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end
end
