defmodule AnkoleWeb.PrincipalControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
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

  test "admin lists active human and agent principals", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("console-human"), display_name: "Console Human"})
    agent = agent_fixture(%{uid: unique_uid("console-agent"), display_name: "Console Agent"})
    disabled = human_fixture(%{uid: unique_uid("console-disabled")})

    assert {:ok, _principal} = Ankole.Principals.disable_principal(disabled.principal.uid)

    conn = conn |> bearer_conn() |> get(~p"/api/v1/principals")
    assert %{"principals" => principals} = json_response(conn, 200)

    assert %{
             "uid" => human_uid,
             "type" => "human",
             "status" => "active",
             "display_name" => "Console Human"
           } = Enum.find(principals, &(&1["uid"] == human.principal.uid))

    assert human_uid == human.principal.uid

    assert %{
             "uid" => agent_uid,
             "type" => "agent",
             "status" => "active",
             "display_name" => "Console Agent"
           } = Enum.find(principals, &(&1["uid"] == agent.principal.uid))

    assert agent_uid == agent.principal.uid
    refute Enum.any?(principals, &(&1["uid"] == disabled.principal.uid))
    assert Enum.map(principals, & &1["uid"]) == Enum.sort(Enum.map(principals, & &1["uid"]))
  end

  test "admin reads one principal with its groups and direct grants", %{conn: conn} do
    conn = bearer_conn(conn)

    %{principal: human} =
      human_fixture(%{uid: unique_uid("principal-detail"), display_name: "Detail Human"})

    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: "detail_group_#{System.unique_integer([:positive])}",
               display_name: "Detail Group"
             })

    assert {:ok, _membership} = AuthZ.add_principal_to_group(human.uid, group.id)

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "workspace:**",
               action: "read"
             })

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/#{human.uid}")
    assert %{"principal" => fetched} = json_response(conn, 200)
    assert fetched["uid"] == human.uid
    assert fetched["display_name"] == "Detail Human"

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/#{human.uid}/groups")
    assert %{"principal_groups" => groups} = json_response(conn, 200)
    assert Enum.map(groups, & &1["name"]) == [group.name]

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/#{human.uid}/grants")
    assert %{"permission_grants" => [listed]} = json_response(conn, 200)
    assert listed["id"] == grant.id
    assert listed["principal_uid"] == human.uid

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/missing-principal")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  defp bearer_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    admin = human_fixture(%{uid: unique_uid("principal-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(admin.principal.uid)

    access_token =
      conn
      |> init_test_session(%{})
      |> WebSession.put_admin_session(%{
        principal_uid: admin.principal.uid,
        provider_id: "lark-main",
        external_id: "external-1"
      })
      |> post(~p"/.internal-apis/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })
      |> json_response(200)
      |> Map.fetch!("access_token")

    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{access_token}")
    |> put_req_header("content-type", "application/json")
  end

  defp recycle_api(conn) do
    conn
    |> recycle()
    |> put_req_header("authorization", get_req_header(conn, "authorization") |> List.first())
    |> put_req_header("content-type", "application/json")
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
