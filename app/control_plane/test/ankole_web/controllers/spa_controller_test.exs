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

    expected = if @host_policy, do: AnkoleWeb.PodURL.site_origin(conn) <> "/setup", else: "/setup"
    assert redirected_to(conn) == expected
  end

  test "GET / opens the edition's home after setup completes", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn = get(conn, ~p"/")

    if @host_policy do
      site = URI.parse(AnkoleWeb.PodURL.site_origin(conn))
      host = String.replace_prefix(site.host, "console.", "accounts.")
      assert redirected_to(conn) == URI.to_string(%{site | host: host, path: "/"})
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

  test "GET /sessions/new serves the tenant's sign-in shell directly without writing ceremony rows",
       %{
         conn: conn,
         tenant: tenant
       } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    browser_count = Ankole.Repo.aggregate(Ankole.BrowserSessions.Session, :count)

    conn = conn |> pod_conn(tenant) |> get(~p"/sessions/new")
    source = Application.fetch_env!(:ankole, :webapp_entries) |> Map.fetch!("auth")

    assert html_response(conn, 200) =~
             ~s(src="http://assets.test/#{String.trim_leading(source, "/")}")

    assert get_resp_header(conn, "location") == []
    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.Session, :count) == browser_count
    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.OidcState, :count) == 0
    assert Ankole.Repo.aggregate(Ankole.OIDC.AuthorizationRequest, :count) == 0
  end

  test "GET /site-admin-console redirects anonymous users to auth after completion", %{conn: conn} do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn = get(conn, ~p"/site-admin-console/settings")

    uri = URI.parse(redirected_to(conn))
    assert uri.path == "/sessions/new"

    assert URI.decode_query(uri.query) == %{
             "purpose" => "console",
             "return_to" => "/site-admin-console/settings"
           }

    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.OidcState, :count) == 0
    assert Ankole.Repo.aggregate(Ankole.OIDC.AuthorizationRequest, :count) == 0
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

  test "the site Console shell uses the backend's bound tenant for feature targeting", %{
    conn: conn,
    tenant: tenant
  } do
    flags = Application.get_env(:ankole, :feature_flags)
    Application.put_env(:ankole, :feature_flags, [{"fixture.shell", [client_visible: true]}])
    Ankole.AppConfigure.Registry.clear_for_test()

    on_exit(fn ->
      if flags == nil,
        do: Application.delete_env(:ankole, :feature_flags),
        else: Application.put_env(:ankole, :feature_flags, flags)

      Ankole.AppConfigure.Registry.clear_for_test()
      Cache.clear_for_test()
    end)

    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)

    {:ok, _} =
      Ankole.AppConfigure.put_global_by_key("features.fixture.shell", %{
        "enabled" => true,
        "percent" => 0,
        "targets" => %{tenant.id => true}
      })

    conn = conn |> active_admin_conn() |> get(~p"/site-admin-console")
    assert Ankole.Features.boolean_value("fixture.shell")

    assert html_response(conn, 200) =~
             ~s(<meta name="ankole-features" content="{&quot;fixture.shell&quot;:true}">)
  end

  test "each Pod's sign-in and workspace HTML shells render in that Pod's configured locale", %{
    conn: conn,
    tenant: first_tenant
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)

    second_tenant =
      Ankole.DataCase.create_tenant(%{
        slug: "pod-ja-#{System.unique_integer([:positive])}",
        display_name: "Tokyo Pod"
      })

    Ankole.Repo.with_tenant(first_tenant.id, fn ->
      {:ok, "zh-Hans-CN"} = Ankole.I18n.put_default_locale("zh-Hans-CN")
    end)

    Ankole.Repo.with_tenant(second_tenant.id, fn ->
      {:ok, "ja-JP"} = Ankole.I18n.put_default_locale("ja-JP")
    end)

    first_login_html =
      conn
      |> pod_conn(first_tenant)
      |> put_req_header("accept-language", "ja,en-US;q=0.8")
      |> get(~p"/sessions/new")
      |> html_response(200)

    second_login_html =
      conn |> pod_conn(second_tenant) |> get(~p"/sessions/new") |> html_response(200)

    assert first_login_html =~ ~s(<html lang="zh-Hans-CN">)
    assert second_login_html =~ ~s(<html lang="ja-JP">)

    first_pod_html =
      conn
      |> pod_conn(first_tenant)
      |> active_admin_conn()
      |> get(~p"/")
      |> html_response(200)

    assert first_pod_html =~ ~s(<html lang="zh-Hans-CN">)
  end

  test "site Console and its sign-in negotiate language independently of the privileged Pod", %{
    conn: conn
  } do
    {:ok, "ko-KR"} = Ankole.I18n.put_default_locale("ko-KR")
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)
    admin = active_admin_conn(conn)

    for {base, path} <- [{conn, "/sessions/new?purpose=console"}, {admin, "/site-admin-console"}],
        {accept_language, locale} <- [
          {"ja,en-US;q=0.8", "ja-JP"},
          {"fr-FR", "en-US"},
          {nil, "en-US"}
        ] do
      request =
        if accept_language,
          do: put_req_header(base, "accept-language", accept_language),
          else: base

      assert request |> get(path) |> html_response(200) =~ ~s(<html lang="#{locale}">)
    end
  end

  defp assert_pod_login(conn, tenant, return_to) do
    uri = URI.parse(redirected_to(conn))
    assert conn.host == URI.parse(AnkoleWeb.PodURL.origin(conn, tenant)).host
    assert uri.host in [nil, conn.host]
    assert uri.path == "/sessions/new"
    assert URI.decode_query(uri.query) == %{"return_to" => return_to}
    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.OidcState, :count) == 0
  end
end
