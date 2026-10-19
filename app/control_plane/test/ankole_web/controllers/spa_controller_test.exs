defmodule AnkoleWeb.SpaControllerTest do
  use AnkoleWeb.ConnCase

  alias Ankole.AppConfigure.Cache
  alias Ankole.Setup.Config, as: SetupConfig

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    allow_cache_database_access()
    Cache.clear_for_test()
    :ok = SetupConfig.delete_bootstrap_activation_code()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok
  end

  test "GET / redirects to setup until setup completes", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / redirects to the tenant's canonical Pod origin after setup completes", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == AnkoleWeb.PodURL.origin(conn, tenant) <> "/"
  end

  test "GET /setup serves setup before completion", %{conn: conn} do
    conn = get(conn, ~p"/setup")

    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/setup.tsx)
  end

  test "GET /setup redirects home after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = get(conn, ~p"/setup")

    assert redirected_to(conn) == ~p"/"
  end

  test "GET /sessions/new serves auth on the tenant host after completion", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = SetupConfig.put_completed(true)

    conn = conn |> Map.put(:host, tenant.slug <> ".ankole.localhost") |> get(~p"/sessions/new")
    next = redirected_to(conn)
    assert next =~ "/sessions/new?flow="
    conn = conn |> recycle() |> get(next)

    assert html_response(conn, 200) =~ ~s(http://assets.test/entrypoints/auth.tsx)
  end

  test "GET /site-admin-console redirects anonymous users to auth after completion", %{conn: conn} do
    {:ok, true} = SetupConfig.put_completed(true)

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
    {:ok, true} = SetupConfig.put_completed(true)

    path = "/pages/" <> Ankole.Kernel.uuid_shorten(Ankole.Kernel.gen_uuid_v7())
    conn = conn |> Map.put(:host, tenant.slug <> ".ankole.localhost") |> get(path)

    flow =
      redirected_to(conn)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("flow")

    assert {:ok, %{purpose: :pod, request: %{"return_to" => ^path}}} =
             AnkoleWeb.Session.login_transaction(conn, flow)
  end

  test "the canonical Pod serves its shell without the console path", %{
    conn: conn,
    tenant: tenant
  } do
    conn =
      conn
      |> Map.put(:host, tenant.slug <> ".ankole.localhost")
      |> active_admin_conn()
      |> get(~p"/")

    html = html_response(conn, 200)

    assert html =~ ~s(http://assets.test/entrypoints/pod.tsx)
    refute html =~ "/site-admin-console"
  end

  test "GET /sessions/new sends a signed-in administrator to the pod", %{
    conn: conn,
    tenant: tenant
  } do
    conn =
      conn
      |> Map.put(:host, tenant.slug <> ".ankole.localhost")
      |> active_admin_conn()
      |> get(~p"/sessions/new")

    assert redirected_to(conn) == ~p"/"
  end
end
