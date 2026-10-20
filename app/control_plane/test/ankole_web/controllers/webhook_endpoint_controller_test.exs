defmodule AnkoleWeb.WebhookEndpointControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import OpenApiSpex.TestAssertions

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  alias Ankole.Signals.Webhooks

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin lists every session endpoint of one agent and cancels without exposing its capability",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    first = source_event!(agent.uid)
    second = source_event!(agent.uid)

    {endpoint, token} = create_endpoint!(agent.uid, first, "Watch GitHub issues")
    {other_session_endpoint, _} = create_endpoint!(agent.uid, second, "Watch releases")
    foreign_source = source_event!(other_agent.uid)
    {foreign, _} = create_endpoint!(other_agent.uid, foreign_source, "Watch mirrors")

    api_spec = AnkoleWeb.APISpec.spec()
    conn = console_conn(conn)

    everything =
      conn
      |> get(~p"/api/v1/webhook-endpoints")
      |> json_response(200)

    assert MapSet.new(everything["webhook_endpoints"], & &1["id"]) ==
             MapSet.new([endpoint.id, other_session_endpoint.id, foreign.id])

    list =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/webhook-endpoints?agent=#{agent.uid}")
      |> json_response(200)

    assert_schema(list, "WebhookEndpointListResponse", api_spec)
    assert %{"webhook_endpoints" => endpoints} = list

    assert MapSet.new(endpoints, & &1["id"]) ==
             MapSet.new([endpoint.id, other_session_endpoint.id])

    assert MapSet.new(endpoints, & &1["session_id"]) ==
             MapSet.new([first.session_id, second.session_id])

    assert Enum.all?(endpoints, &(&1["status"] == "active"))
    refute inspect(list) =~ token
    refute inspect(list) =~ Webhooks.token_digest(token)

    assert conn
           |> recycle_api()
           |> delete(~p"/api/v1/agents/#{other_agent.uid}/webhook-endpoints/#{endpoint.id}")
           |> json_response(404)

    cancelled =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent.uid}/webhook-endpoints/#{endpoint.id}")
      |> json_response(200)

    assert_schema(cancelled, "WebhookEndpointResponse", api_spec)
    assert get_in(cancelled, ["webhook_endpoint", "status"]) == "cancelled"
  end

  test "missing browser session is rejected", %{conn: conn} do
    assert conn
           |> get(~p"/api/v1/webhook-endpoints")
           |> json_response(401)
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
