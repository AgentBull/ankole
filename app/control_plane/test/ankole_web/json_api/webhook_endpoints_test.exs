defmodule AnkoleWeb.JSONAPI.WebhookEndpointsTest do
  @moduledoc "Checks the webhook endpoint routes of `/api/v2`."
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ.Grant
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.Signals.Webhooks

  @json_api "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "admin lists the endpoints of all Agents or of one Agent without their capability",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    first = source_event!(agent.uid)
    second = source_event!(agent.uid)

    {endpoint, token} = create_endpoint!(agent.uid, first, "Watch GitHub issues")
    {other_session_endpoint, _} = create_endpoint!(agent.uid, second, "Watch releases")
    {foreign, _} = create_endpoint!(other_agent.uid, source_event!(other_agent.uid), "Mirrors")

    conn = console_conn(conn)

    everything = conn |> request(:get, "/api/v2/webhook-endpoints") |> json_response(200)

    assert MapSet.new(everything["data"], & &1["id"]) ==
             MapSet.new([endpoint.id, other_session_endpoint.id, foreign.id])

    list =
      conn |> request(:get, "/api/v2/webhook-endpoints?agent=#{agent.uid}") |> json_response(200)

    assert MapSet.new(list["data"], & &1["id"]) ==
             MapSet.new([endpoint.id, other_session_endpoint.id])

    assert MapSet.new(list["data"], & &1["attributes"]["session_id"]) ==
             MapSet.new([first.session_id, second.session_id])

    assert Enum.all?(list["data"], &(&1["attributes"]["status"] == "active"))
    refute inspect(list) =~ token
    refute inspect(list) =~ Webhooks.token_digest(token)

    assert %{"errors" => [_ | _]} =
             conn
             |> request(:get, "/api/v2/webhook-endpoints?fields[webhook_endpoint]=token_digest")
             |> json_response(400)
  end

  test "admin creates a CloudEvents endpoint once and cancels it", %{conn: conn} do
    conn = console_conn(conn)
    expires_at = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1, :hour))

    created =
      conn
      |> request(:post, "/api/v2/webhook-endpoints", %{label: "Events", expires_at: expires_at})
      |> json_response(201)

    assert %{
             "webhook_endpoint" => %{
               "id" => id,
               "event_format" => "cloudevents",
               "mode" => "standing",
               "status" => "active",
               "agent_uid" => nil
             },
             "token" => "wh_" <> _secret = token
           } = created

    refute Map.has_key?(created["webhook_endpoint"], "token_digest")

    listed = conn |> request(:get, "/api/v2/webhook-endpoints") |> json_response(200)
    assert [%{"id" => ^id}] = listed["data"]
    refute inspect(listed) =~ token

    assert %{"errors" => [%{"code" => "webhook_expiry_must_be_future"}]} =
             conn
             |> request(:post, "/api/v2/webhook-endpoints", %{
               label: "Late",
               expires_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1, :hour))
             })
             |> json_response(422)

    assert %{"errors" => [%{"source" => %{"pointer" => "/data/label"}}]} =
             conn
             |> request(:post, "/api/v2/webhook-endpoints", %{expires_at: expires_at})
             |> json_response(400)

    cancelled =
      conn |> request(:delete, "/api/v2/webhook-endpoints/#{id}") |> json_response(200)

    assert %{"id" => ^id, "status" => "cancelled"} = cancelled

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> request(:delete, "/api/v2/webhook-endpoints/#{Ecto.UUID.generate()}")
             |> json_response(404)
  end

  test "disabling an unknown signal binding is not found", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    for agent_uid <- [agent.uid, "agt_missing"] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn
               |> request(:delete, "/api/v2/agents/#{agent_uid}/signal-bindings/missing")
               |> json_response(404)
    end
  end

  test "a request without the webhook grant changes nothing", %{conn: conn} do
    {conn, admin_uid} = console_conn_with_principal(conn)
    {endpoint, _token} = create_endpoint!(nil, nil, "Granted")

    Repo.delete_all(
      from grant in Grant,
        where:
          grant.resource_pattern in ["site_console:**", "tenant_console:**"] or
            grant.principal_uid == ^admin_uid
    )

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             conn
             |> request(:delete, "/api/v2/webhook-endpoints/#{endpoint.id}")
             |> json_response(403)

    assert Webhooks.get_endpoint(endpoint.id).status == :active
  end

  test "missing browser session is rejected", %{conn: conn} do
    assert conn |> get(~p"/api/v2/webhook-endpoints") |> json_response(401)
  end

  defp request(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @json_api)
    |> put_req_header("content-type", @json_api)
    |> dispatch(@endpoint, method, path, if(data, do: Jason.encode!(%{data: data}), else: ""))
  end

  defp create_endpoint!(nil, nil, label) do
    assert {:ok, %{webhook_endpoint: endpoint, token: token}} =
             Webhooks.create_endpoint(%{
               label: label,
               mode: "standing",
               event_format: "cloudevents",
               source_provenance: %{"kind" => "console-test"},
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
             })

    {endpoint, token}
  end

  defp create_endpoint!(agent_uid, source, label) do
    assert {:ok, %{webhook_endpoint: endpoint, token: token}} =
             Webhooks.create_endpoint(%{
               agent_uid: agent_uid,
               binding_name: source.reply_binding_name,
               session_id: source.session_id,
               conversation_id: source.conversation_id,
               provider_thread_id: source.provider_thread_id,
               source_signal_id: source.id,
               provider_message_id: source.provider_message_id,
               source_provenance: %{"kind" => "console-test"},
               label: label,
               mode: "standing",
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
             })

    {endpoint, token}
  end

  defp source_event!(agent_uid) do
    Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid,
      binding_name: "github",
      source: "test://webhook-source"
    )
  end
end
