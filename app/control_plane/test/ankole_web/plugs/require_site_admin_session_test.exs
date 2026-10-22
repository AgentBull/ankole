defmodule AnkoleWeb.Plugs.RequireSiteAdminSessionTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AuthZ
  alias Ankole.Principals.HumanAccess
  alias Ankole.Repo

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "the Console accepts a browser session and rejects requests without one", %{conn: conn} do
    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> get(~p"/api/v1/agents") |> json_response(401)

    assert conn |> console_conn() |> get(~p"/api/v1/agents") |> json_response(200)
  end

  test "a cookie does not bypass CSRF for writes", %{conn: conn} do
    conn = conn |> console_conn() |> get(~p"/api/v1/agents")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post(~p"/api/v1/agents", %{})
    end
  end

  test "removing site administration revokes the next request", %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    conn = get(conn, ~p"/api/v1/agents")
    Repo.put_tenant_id(tenant.id)
    add_second_admin()
    assert {:ok, _} = AuthZ.remove_principal_from_group(uid, "siteadmin")

    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> recycle_api() |> get(~p"/api/v1/agents") |> json_response(401)
  end

  test "disabling a Human revokes the next request", %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    conn = get(conn, ~p"/api/v1/agents")
    Repo.put_tenant_id(tenant.id)
    add_second_admin()
    assert {:ok, _} = HumanAccess.disable(uid, "Offboarding", nil, "console-disable")

    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> recycle_api() |> get(~p"/api/v1/agents") |> json_response(401)
  end

  test "logout ends the cookie session", %{conn: conn} do
    conn = conn |> console_conn() |> get(~p"/api/v1/agents")
    conn = conn |> recycle_api() |> delete(~p"/.internal-apis/session")
    assert response(conn, 200)

    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> recycle_api() |> get(~p"/api/v1/agents") |> json_response(401)
  end

  test "a valid Agent bearer token cannot authenticate the Console", %{conn: conn} do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    {:ok, token} = Ankole.AIGateway.Tokens.mint_for_agent(agent.uid)

    assert %{"error" => %{"code" => "unauthorized"}} =
             conn
             |> put_req_header("authorization", "Bearer #{token.api_key}")
             |> get(~p"/api/v1/agents")
             |> json_response(401)
  end

  test "an unknown data tenant returns its existing error", %{conn: conn} do
    assert %{"error" => %{"code" => "data_tenant_unavailable"}} =
             conn
             |> console_conn()
             |> put_req_header("x-ankole-tenant", Ecto.UUID.generate())
             |> get(~p"/api/v1/agents")
             |> json_response(404)
  end

  defp add_second_admin do
    %{principal: principal} = Ankole.PrincipalsFixtures.human_fixture()
    assert {:ok, _} = AuthZ.add_principal_to_group(principal.uid, "siteadmin")
  end
end
