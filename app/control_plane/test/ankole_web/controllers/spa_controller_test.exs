defmodule AnkoleWeb.SpaControllerTest do
  use AnkoleWeb.ConnCase

  alias Ankole.Setup.Config, as: SetupConfig

  @host_policy Application.compile_env(:ankole, :host_policy)

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
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
    html = conn |> get(~p"/setup") |> html_response(200)

    assert html =~ ~s(http://assets.test/entrypoints/setup.tsx)
    assert html =~ ~s(<link rel="icon" type="image/svg+xml" href="/images/logo.svg">)
    assert html =~ ~s(<link rel="icon" href="/favicon.ico" sizes="48x48">)
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

    conn =
      if @host_policy do
        target = redirected_to(conn)
        uri = URI.parse(target)
        assert String.starts_with?(uri.host, "accounts.")
        assert uri.path == "/sessions/new"
        assert URI.decode_query(uri.query) == %{"tenant_id" => tenant.id}
        conn |> recycle() |> get(target)
      else
        assert get_resp_header(conn, "location") == []
        conn
      end

    assert html_response(conn, 200) =~
             ~s(src="http://assets.test/#{String.trim_leading(source, "/")}")

    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.Session, :count) == browser_count
    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.OidcState, :count) == 0
    assert Ankole.Repo.aggregate(Ankole.OIDC.AuthorizationRequest, :count) == 0
  end

  test "GET /site-admin-console redirects anonymous users to privileged Pod login with a sealed console_return ticket",
       %{
         conn: conn,
         tenant: tenant
       } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    conn = get(conn, ~p"/site-admin-console/settings")
    location = redirected_to(conn)

    refute location =~ "/site-admin-console"
    uri = URI.parse(location)
    assert uri.path == "/sessions/new"
    query = URI.decode_query(uri.query)

    assert {:ok, "/site-admin-console/settings"} =
             AnkoleWeb.Session.unseal_console_return(query["console_return"], tenant.id)

    if @host_policy do
      assert String.starts_with?(uri.host, "accounts.")
      assert query["tenant_id"] == tenant.id
    else
      assert uri.host == URI.parse(AnkoleWeb.PodURL.origin(conn, tenant)).host
    end

    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.OidcState, :count) == 0
    assert Ankole.Repo.aggregate(Ankole.OIDC.AuthorizationRequest, :count) == 0
  end

  test "signing into the privileged Pod as siteadmin immediately opens Console and site APIs without a second login",
       %{conn: conn, tenant: tenant} do
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)

    %{principal: site_scoped_admin} =
      Ankole.PrincipalsFixtures.human_fixture(%{
        uid: Ankole.PrincipalsFixtures.unique_uid("site-scope-admin")
      })

    %{principal: tenant_scoped_admin} =
      Ankole.PrincipalsFixtures.human_fixture(%{
        uid: Ankole.PrincipalsFixtures.unique_uid("tenant-scope-admin")
      })

    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(site_scoped_admin.uid)
    {:ok, _} = Ankole.AuthZ.add_principal_to_group(tenant_scoped_admin.uid, "siteadmin")

    email = "site-scope-admin@example.com"

    {:ok, _} =
      Ankole.Repo.transact(fn ->
        Ankole.Principals.bind_site_credential_in_tx(site_scoped_admin.uid, %{
          provider_id: "test-site",
          subject_id: email,
          verified_email: email
        })
      end)

    previous_sources = Application.get_env(:ankole, :site_identity_sources, [])

    defmodule ConsoleDirectSiteSource do
      @behaviour Ankole.IdentityProviders.SiteSources
      def authenticate(proof), do: {:ok, proof}
      def login_path, do: "/test/site-login"
      def display_name, do: "Test site source"
      def fresh_authentication?, do: true
    end

    Application.put_env(:ankole, :site_identity_sources, [{"test-site", ConsoleDirectSiteSource}])
    on_exit(fn -> Application.put_env(:ankole, :site_identity_sources, previous_sources) end)

    site_auth_conn =
      conn
      |> init_test_session(%{})
      |> AnkoleWeb.Session.ensure_browser()
      |> then(fn base ->
        {:ok, %{browser: browser, authentication: auth}} =
          Ankole.BrowserSessions.authenticate_site(
            AnkoleWeb.Session.browser_reference(base),
            "test-site",
            %{
              subject_id: email,
              verified_email: email,
              auth_time: System.system_time(:second),
              challenge_started_at: DateTime.utc_now(),
              amr: ["otp"]
            },
            scope: :site,
            target_tenant_id: tenant.id
          )

        AnkoleWeb.Session.put_authentication(base, browser, auth)
      end)

    tenant_auth_conn =
      conn
      |> init_test_session(%{})
      |> AnkoleWeb.Session.put_tenant_session(%{
        principal_uid: tenant_scoped_admin.uid,
        provider_id: "lark-main",
        external_id: "ext-admin"
      })

    for {signed_conn, expected_uid} <- [
          {site_auth_conn, site_scoped_admin.uid},
          {tenant_auth_conn, tenant_scoped_admin.uid}
        ] do
      shell = get(signed_conn, ~p"/site-admin-console")
      html = html_response(shell, 200)

      assert html =~
               ~s(<meta name="ankole-site-admin-console-path" content="/site-admin-console">)

      assert html =~ ~s(<meta name="ankole-principal" content="#{expected_uid}">)

      api_conn =
        shell
        |> recycle()
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v2/site/tenants")

      assert json_response(api_conn, 200)["data"] != []
    end

    %{principal: member} =
      Ankole.PrincipalsFixtures.human_fixture(%{
        uid: Ankole.PrincipalsFixtures.unique_uid("console-non-admin")
      })

    member_conn =
      conn
      |> init_test_session(%{})
      |> AnkoleWeb.Session.put_tenant_session(%{
        principal_uid: member.uid,
        provider_id: "lark-main",
        external_id: "ext-member"
      })

    assert get(member_conn, ~p"/site-admin-console/tenants").status == 403

    switched = get(member_conn, "/site-admin-console/tenants?sort=name&switch=1")
    redirect_uri = URI.parse(redirected_to(switched))
    query = URI.decode_query(redirect_uri.query || "")
    assert query["switch"] == "1"

    assert {:ok, "/site-admin-console/tenants?sort=name"} =
             AnkoleWeb.Session.unseal_console_return(query["console_return"], tenant.id)
  end

  test "multi-account browser resolves siteadmin authentication for Console when active_authentication_id belongs to another Pod",
       %{conn: conn, tenant: privileged} do
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)
    other_pod = Ankole.DataCase.create_tenant()

    %{principal: admin} =
      Ankole.PrincipalsFixtures.human_fixture(%{
        uid: Ankole.PrincipalsFixtures.unique_uid("multi-admin")
      })

    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(admin.uid)

    other_member =
      Ankole.Repo.with_tenant(other_pod.id, fn ->
        Ankole.PrincipalsFixtures.human_fixture(%{
          uid: Ankole.PrincipalsFixtures.unique_uid("other-pod-member")
        }).principal
      end)

    conn = conn |> init_test_session(%{}) |> AnkoleWeb.Session.ensure_browser()
    browser_ref = AnkoleWeb.Session.browser_reference(conn)

    {:ok, %{browser: b1, authentication: admin_auth}} =
      Ankole.BrowserSessions.authenticate(browser_ref, %{
        "principal_uid" => admin.uid,
        "access_version" => admin.access_version,
        "provider_id" => "lark-main",
        "external_id" => "admin-ext"
      })

    conn = AnkoleWeb.Session.put_authentication(conn, b1, admin_auth)
    admin_ref = Ankole.BrowserSessions.reference(admin_auth)

    # A non-admin candidate must not hide an administrator in the same browser.
    member = Ankole.PrincipalsFixtures.human_fixture().principal

    {:ok, %{browser: member_browser, authentication: member_auth}} =
      Ankole.BrowserSessions.authenticate(browser_ref, %{
        "principal_uid" => member.uid,
        "access_version" => member.access_version,
        "provider_id" => "lark-main",
        "external_id" => "ordinary-member"
      })

    conn = AnkoleWeb.Session.put_authentication(conn, member_browser, member_auth)

    assert {:ok, %{"principal_uid" => resolved_uid}, ^admin_ref} =
             AnkoleWeb.Session.resolve_site_admin_session(conn)

    assert resolved_uid == admin.uid

    explicit_member =
      Plug.Conn.put_req_header(
        conn,
        "x-ankole-authentication",
        Ankole.BrowserSessions.encode_reference(Ankole.BrowserSessions.reference(member_auth))
      )

    assert :forbidden = AnkoleWeb.Session.resolve_site_admin_session(explicit_member)

    {:ok, %{browser: b2, authentication: other_auth}} =
      Ankole.Repo.with_tenant(other_pod.id, fn ->
        Ankole.BrowserSessions.authenticate(browser_ref, %{
          "principal_uid" => other_member.uid,
          "access_version" => other_member.access_version,
          "provider_id" => "lark-other",
          "external_id" => "other-ext"
        })
      end)

    conn = AnkoleWeb.Session.put_authentication(conn, b2, other_auth)
    other_ref = Ankole.BrowserSessions.reference(other_auth)
    assert AnkoleWeb.Session.authentication_reference(conn) == other_ref

    shell = get(conn, ~p"/site-admin-console")
    html = html_response(shell, 200)
    encoded_admin_ref = Ankole.BrowserSessions.encode_reference(admin_ref)

    assert html =~ ~s(<meta name="ankole-authentication" content="#{encoded_admin_ref}">)
    assert html =~ ~s(<meta name="ankole-principal" content="#{admin.uid}">)
    assert get_session(shell, "_csrf_token") == nil

    assert Ankole.BrowserSessions.current_reference(AnkoleWeb.Session.browser_reference(shell)) ==
             other_ref

    [_, meta_csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html)
    origin = AnkoleWeb.PodURL.site_origin(shell)

    pinned_post =
      shell
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("origin", origin)
      |> put_req_header("x-csrf-token", meta_csrf)
      |> put_req_header("x-ankole-authentication", encoded_admin_ref)
      |> post(
        "/api/v2/browser/authentications/current",
        Ankole.JSON.encode!(%{
          data: %{authenticationRef: encoded_admin_ref, tenantID: privileged.id}
        })
      )

    assert json_response(pinned_post, 201)["podURL"] ==
             AnkoleWeb.PodURL.origin(shell, privileged) <> "/"
  end

  test "non-admin member of the privileged Pod receives 403 on Console without Console shell metadata or login redirect loop",
       %{conn: conn} do
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)

    %{principal: member} =
      Ankole.PrincipalsFixtures.human_fixture(%{
        uid: Ankole.PrincipalsFixtures.unique_uid("ordinary-member")
      })

    conn =
      conn
      |> init_test_session(%{})
      |> AnkoleWeb.Session.put_tenant_session(%{
        principal_uid: member.uid,
        provider_id: "lark-main",
        external_id: "ordinary-ext"
      })
      |> get(~p"/site-admin-console")

    assert conn.status == 403
    assert conn.resp_body == "Site administrator access required"
    assert get_resp_header(conn, "location") == []
    refute conn.resp_body =~ "ankole-site-admin-console-path"
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

    if @host_policy do
      accounts_target = redirected_to(conn)
      assert URI.parse(accounts_target).path == "/sessions/new"
      entered = conn |> recycle() |> get(accounts_target)
      assert redirected_to(entered) == AnkoleWeb.PodURL.origin(conn, tenant) <> "/"
    else
      assert redirected_to(conn) == ~p"/"
    end
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
      |> follow_login_redirect()
      |> html_response(200)

    second_login_html =
      conn
      |> pod_conn(second_tenant)
      |> get(~p"/sessions/new")
      |> follow_login_redirect()
      |> html_response(200)

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

  test "site Console and its sign-in render in the privileged Pod's locale while tenant-less shells negotiate Accept-Language",
       %{conn: conn} do
    {:ok, "ko-KR"} = Ankole.I18n.put_default_locale("ko-KR")
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)

    other_tenant =
      Ankole.DataCase.create_tenant(%{
        slug: "pod-zh-#{System.unique_integer([:positive])}",
        display_name: "Shanghai Pod"
      })

    Ankole.Repo.with_tenant(other_tenant.id, fn ->
      {:ok, "zh-Hans-CN"} = Ankole.I18n.put_default_locale("zh-Hans-CN")
    end)

    admin = active_admin_conn(conn)

    for accept_language <- ["ja,en-US;q=0.8", "fr-FR", nil] do
      anon_request =
        if accept_language,
          do: put_req_header(conn, "accept-language", accept_language),
          else: conn

      login_shell =
        anon_request
        |> get("/site-admin-console")
        |> follow_login_redirect()
        |> follow_login_redirect()

      assert html_response(login_shell, 200) =~ ~s(<html lang="ko-KR">)

      admin_request =
        if accept_language,
          do: put_req_header(admin, "accept-language", accept_language),
          else: admin

      assert admin_request |> get("/site-admin-console") |> html_response(200) =~
               ~s(<html lang="ko-KR">)
    end

    for {accept_language, locale} <- [
          {"ja,en-US;q=0.8", "ja-JP"},
          {"fr-FR", "en-US"},
          {nil, "en-US"}
        ] do
      request =
        if accept_language,
          do: put_req_header(conn, "accept-language", accept_language),
          else: conn

      assert request |> get(~p"/sessions/logged-out") |> html_response(200) =~
               ~s(<html lang="#{locale}">)
    end
  end

  test "SPA shells advertise /dev/mailbox only when the local mailer adapter is active", %{
    conn: conn
  } do
    previous = Application.get_env(:ankole, Ankole.Authn.Mailer)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:ankole, Ankole.Authn.Mailer),
        else: Application.put_env(:ankole, Ankole.Authn.Mailer, previous)
    end)

    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.SMTP)
    refute conn |> get(~p"/setup") |> html_response(200) =~ "ankole-dev-mailbox"

    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Local)

    assert conn |> get(~p"/setup") |> html_response(200) =~
             ~s(<meta name="ankole-dev-mailbox" content="/dev/mailbox">)
  end

  defp follow_login_redirect(%{status: 302} = conn),
    do: conn |> recycle() |> get(redirected_to(conn))

  defp follow_login_redirect(conn), do: conn

  defp assert_pod_login(conn, tenant, return_to) do
    uri = URI.parse(redirected_to(conn))
    assert conn.host == URI.parse(AnkoleWeb.PodURL.origin(conn, tenant)).host

    if @host_policy do
      assert String.starts_with?(uri.host, "accounts.")
      assert uri.path == "/sessions/new"

      assert URI.decode_query(uri.query) == %{
               "tenant_id" => tenant.id,
               "return_to" => return_to
             }
    else
      assert uri.host in [nil, conn.host]
      assert uri.path == "/sessions/new"
      assert URI.decode_query(uri.query) == %{"return_to" => return_to}
    end

    assert Ankole.Repo.aggregate(Ankole.BrowserSessions.OidcState, :count) == 0
  end
end
