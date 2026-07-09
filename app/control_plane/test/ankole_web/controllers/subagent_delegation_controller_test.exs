defmodule AnkoleWeb.SubagentDelegationControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query, warn: false
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "OpenAPI JSON includes the three delegation endpoints", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi.json") |> json_response(200) |> Map.fetch!("paths")

    assert Map.has_key?(paths, "/api/v1/delegations")
    assert Map.has_key?(paths, "/api/v1/delegations/{delegation_id}")
    assert Map.has_key?(paths, "/api/v1/delegations/{delegation_id}/cancel")
  end

  test "admin lists with filters and cursor, reads the timeline, and cancels", %{conn: conn} do
    agent = agent_fixture().principal
    other_agent = agent_fixture().principal
    oldest = create_delegation!(agent.uid, "oldest")
    middle = create_delegation!(agent.uid, "middle")
    newest = create_delegation!(other_agent.uid, "newest")

    set_queued_at(oldest, ~U[2026-07-10 01:00:00.000000Z])
    set_queued_at(middle, ~U[2026-07-10 02:00:00.000000Z])
    set_queued_at(newest, ~U[2026-07-10 03:00:00.000000Z])

    assert {:ok, _event} =
             SubagentDelegations.append_event(%{
               "agent_uid" => agent.uid,
               "delegation_id" => middle.id,
               "seq" => 0,
               "direction" => "process",
               "event_type" => "thread_started",
               "payload" => %{"thread_id" => "thread-console"}
             })

    conn = bearer_conn(conn)
    first_page = conn |> get(~p"/api/v1/delegations?limit=2") |> json_response(200)

    assert Enum.map(first_page["data"], & &1["id"]) == [newest.id, middle.id]
    assert is_binary(first_page["next_cursor"])

    second_page =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/delegations?limit=2&cursor=#{first_page["next_cursor"]}")
      |> json_response(200)

    assert Enum.map(second_page["data"], & &1["id"]) == [oldest.id]
    assert second_page["next_cursor"] == nil

    filtered =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/delegations?agent=#{agent.uid}&status=queued")
      |> json_response(200)

    assert Enum.map(filtered["data"], & &1["id"]) == [middle.id, oldest.id]

    detail =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/delegations/#{middle.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert detail["title"] == middle.title
    assert [%{"seq" => 0, "event_type" => "thread_started"}] = detail["events"]

    cancelled =
      conn
      |> recycle_bearer()
      |> post(~p"/api/v1/delegations/#{middle.id}/cancel")
      |> json_response(200)
      |> Map.fetch!("data")

    assert cancelled["status"] == "stopped"
    assert cancelled["metadata"]["cancel_requested_by"] =~ "operator:"
  end

  test "missing bearer token is rejected", %{conn: conn} do
    assert conn |> get(~p"/api/v1/delegations") |> json_response(401)
  end

  defp create_delegation!(agent_uid, suffix) do
    assert {:ok, %{delegation: delegation}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "session_id" => "console-parent-#{suffix}",
               "tool_call_id" => "console-tool-#{suffix}",
               "title" => "Console delegation #{suffix}",
               "prompt" => "Complete console delegation #{suffix}.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "console-chat-#{suffix}"
               }
             })

    delegation
  end

  defp set_queued_at(delegation, queued_at) do
    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [queued_at: queued_at])
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
    human = human_fixture(%{uid: unique_uid("delegation-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
