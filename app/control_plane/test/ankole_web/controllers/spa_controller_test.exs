defmodule AnkoleWeb.SpaControllerTest do
  use AnkoleWeb.ConnCase

  alias Ankole.AppConfigure.Cache
  alias Ankole.Setup.Config, as: SetupConfig

  @host_policy Application.compile_env(:ankole, :host_policy)

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    Cache.clear_for_test()
    :ok = SetupConfig.delete_bootstrap_activation_code()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok
  end

  test "GET / redirects to setup until setup completes", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / opens the edition's home after setup completes", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn = get(conn, ~p"/")

    if @host_policy do
      assert redirected_to(conn) == "/account"
    else
      assert redirected_to(conn) == AnkoleWeb.PodURL.origin(conn, tenant) <> "/"
    end
  end

  test "GET /setup serves setup before completion", %{conn: conn} do
    conn = get(conn, ~p"/setup")

    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/setup.tsx)
  end

  test "GET /setup redirects home after completion", %{conn: conn} do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn = get(conn, ~p"/setup")

    assert redirected_to(conn) == ~p"/"
  end

  test "GET /sessions/new starts the tenant's browser login after completion", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn = conn |> pod_conn(tenant) |> get(~p"/sessions/new")
    assert_pod_login(conn, tenant, "/")

    conn = conn |> recycle() |> get(redirected_to(conn))
    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/auth.tsx)
  end

  test "GET /site-admin-console redirects anonymous users to auth after completion", %{conn: conn} do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn = get(conn, ~p"/site-admin-console/settings")

    flow =
      redirected_to(conn)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("flow")

    assert {:ok, %{purpose: :console, request: %{"return_to" => "/site-admin-console/settings"}}} =
             AnkoleWeb.Session.login_transaction(conn, flow)
  end

  test "the canonical Page redirects anonymous users to auth with its short path intact", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    path = "/pages/" <> Ankole.Kernel.uuid_shorten(Ankole.Kernel.gen_uuid_v7())
    conn = conn |> pod_conn(tenant) |> get(path)
    assert_pod_login(conn, tenant, path)
  end

  test "the canonical Pod serves its shell without the console path", %{
    conn: conn,
    tenant: tenant
  } do
    conn =
      conn
      |> pod_conn(tenant)
      |> active_admin_conn()
      |> get(~p"/")

    html = html_response(conn, 200)

    entry = if @host_policy, do: "saas-pod", else: "pod"
    source = Application.fetch_env!(:ankole, :webapp_entries) |> Map.fetch!(entry)
    assert html =~ "http://assets.test/#{String.trim_leading(source, "/")}"
    refute html =~ "/site-admin-console"
  end

  test "GET /sessions/new uses the edition's Pod entry for a signed-in administrator", %{
    conn: conn,
    tenant: tenant
  } do
    conn =
      conn
      |> pod_conn(tenant)
      |> active_admin_conn()
      |> get(~p"/sessions/new")

    assert redirected_to(conn) == ~p"/"
  end

  defp assert_pod_login(conn, tenant, return_to) do
    uri = URI.parse(redirected_to(conn))
    assert uri.host in [nil, conn.host]
    assert uri.path == "/sessions/new"
    flow = URI.decode_query(uri.query) |> Map.fetch!("flow")

    assert {:ok, %{purpose: :pod, tenant_id: id, request: %{"return_to" => ^return_to}}} =
             AnkoleWeb.Session.login_transaction(conn, flow)

    assert id == tenant.id
  end
end
