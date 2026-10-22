defmodule AnkoleWeb.PodIdentitySelectionTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{BrowserSessions, Repo}
  alias AnkoleWeb.PodURL
  alias AnkoleWeb.SessionCookies
  alias AnkoleWeb.Session, as: WebSession

  @host_policy Application.compile_env(:ankole, :host_policy)

  setup %{tenant: tenant, conn: base_conn} do
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    original = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)
    configured = Keyword.put(original, :url, host: "ankole.localhost", port: 4002)
    Application.put_env(:ankole, AnkoleWeb.Endpoint, configured)
    AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, configured}], [])

    on_exit(fn ->
      Application.put_env(:ankole, AnkoleWeb.Endpoint, original)
      AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, original}], [])
    end)

    a = human_fixture(%{display_name: "First account"}).principal
    b = human_fixture(%{display_name: "Second account"}).principal
    base_conn = %{base_conn | scheme: :http, port: 4002}
    origin = PodURL.origin(base_conn, tenant)
    domain = if @host_policy, do: apply(@host_policy, :domain, []), else: "ankole.localhost"

    conn =
      build_conn(:get, origin <> "/")
      |> Map.put(:secret_key_base, AnkoleWeb.Endpoint.config(:secret_key_base))
      |> SessionCookies.call([])
      |> fetch_session()

    {first, a_ref} = login(conn, a)
    {signed, b_ref} = login(first, b)

    %{
      signed: signed,
      a: a,
      b: b,
      a_ref: a_ref,
      b_ref: b_ref,
      origin: origin,
      site_origin: PodURL.site_origin(conn),
      domain: domain
    }
  end

  test "ordinary Pod logins keep both proofs with one shared cookie scope", ctx do
    assert {:ok, _} = BrowserSessions.get_authentication(ctx.a_ref)
    assert {:ok, _} = BrowserSessions.get_authentication(ctx.b_ref)
    assert length(WebSession.authentication_references(ctx.signed)) == 2
    assert WebSession.authentication_reference(ctx.signed) == ctx.b_ref

    response = send_resp(ctx.signed, 200, "")
    cookies = response.resp_cookies
    assert cookies["_ankole_key"].domain == ctx.domain

    for ref <- [ctx.a_ref, ctx.b_ref] do
      cookie = cookies[SessionCookies.authentication_prefix() <> ref["id"]]
      assert cookie.domain == ctx.domain
      assert cookie.path == "/"
      assert cookie.same_site == "Lax"
      assert cookie.http_only
    end
  end

  test "cookie scope uses the canonical domain policy instead of a literal Endpoint IP" do
    original = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)

    for host <- ["127.0.0.1", "192.168.1.42", "::1", "2001:db8::42"] do
      configured = Keyword.put(original, :url, host: host)
      Application.put_env(:ankole, AnkoleWeb.Endpoint, configured)
      AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, configured}], [])

      if @host_policy do
        domain = apply(@host_policy, :domain, [])
        assert SessionCookies.domain() == domain
        assert SessionCookies.options()[:domain] == domain
      else
        assert is_nil(SessionCookies.domain())
        refute Keyword.has_key?(SessionCookies.options(), :domain)
      end
    end
  end

  test "the existing Pod chooser switches a proven account and keeps an open tab pinned", ctx do
    {shell, flow} = chooser(ctx.signed, ctx.tenant)

    choices =
      shell
      |> recycle()
      |> put_req_header("accept", "application/json")
      |> get(auth_origin(shell, ctx.tenant) <> "/.internal-apis/identity-providers?flow=#{flow}")

    assert %{"identities" => identities} = json_response(choices, 200)

    assert Enum.sort(Enum.map(identities, & &1["principalUID"])) ==
             Enum.sort([ctx.a.uid, ctx.b.uid])

    selected = select(shell, ctx.tenant, flow, ctx.a_ref)
    assert %{"returnTo" => "/content/space"} = json_response(selected, 200)
    assert BrowserSessions.current_reference(WebSession.browser_reference(selected)) == ctx.a_ref
    assert {:error, :login_expired} = WebSession.login_transaction(selected, flow)

    pinned =
      selected
      |> recycle()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-ankole-authentication", BrowserSessions.encode_reference(ctx.b_ref))
      |> get(ctx.origin <> "/.internal-apis/session")

    assert json_response(pinned, 200)["principalUID"] == ctx.b.uid

    current =
      selected
      |> recycle()
      |> put_req_header("accept", "text/html")
      |> get(ctx.origin <> "/")

    [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, current.resp_body)

    revoked =
      current
      |> recycle()
      |> put_req_header("x-ankole-authentication", BrowserSessions.encode_reference(ctx.a_ref))
      |> put_req_header("x-csrf-token", csrf)
      |> put_req_header("origin", ctx.origin)
      |> put_req_header("accept", "application/json")
      |> delete(ctx.origin <> "/.internal-apis/authentications/current")

    assert json_response(revoked, 200) == %{"ok" => true}
    deleted = revoked.resp_cookies[SessionCookies.authentication_prefix() <> ctx.a_ref["id"]]
    assert deleted.domain == ctx.domain
    assert deleted.path == "/"
    assert deleted.max_age == 0
    assert {:ok, _} = BrowserSessions.get_authentication(ctx.b_ref)
  end

  test "the session lists proved accounts across tenants and activates one for its Pod", ctx do
    foreign = Ankole.DataCase.create_tenant()

    {signed, c_ref, c} =
      Repo.with_tenant(foreign.id, fn ->
        c = human_fixture(%{display_name: "Foreign account"}).principal
        {conn, ref} = login(ctx.signed, c)
        {conn, ref, c}
      end)

    pinned = BrowserSessions.encode_reference(ctx.a_ref)

    shell =
      signed
      |> put_req_header("accept", "text/html")
      |> put_req_header("x-ankole-authentication", pinned)
      |> get(ctx.origin <> "/")

    [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, shell.resp_body)

    session =
      shell
      |> recycle()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-ankole-authentication", pinned)
      |> get(ctx.origin <> "/.internal-apis/session")
      |> AnkoleWeb.InternalAPIContract.json_response(200)

    assert session["displayName"] == "First account"
    assert session["tenant"]["id"] == ctx.a.tenant_id
    assert session["consoleURL"] == nil

    assert Enum.sort(Enum.map(session["accounts"], &{&1["tenant"]["id"], &1["displayName"]})) ==
             Enum.sort([
               {ctx.a.tenant_id, "First account"},
               {ctx.a.tenant_id, "Second account"},
               {foreign.id, "Foreign account"}
             ])

    foreign_account = Enum.find(session["accounts"], &(&1["principalUID"] == c.uid))
    assert foreign_account["podURL"] == PodURL.origin(shell, foreign) <> "/"
    assert foreign_account["authenticationRef"] == BrowserSessions.encode_reference(c_ref)

    activate = fn ref ->
      shell
      |> recycle()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-ankole-authentication", pinned)
      |> put_req_header("x-csrf-token", csrf)
      |> put_req_header("origin", ctx.site_origin)
      |> put(ctx.site_origin <> "/.internal-apis/sessions/active", %{authenticationRef: ref})
    end

    activated = activate.(foreign_account["authenticationRef"])
    assert json_response(activated, 200) == %{"podURL" => foreign_account["podURL"]}
    assert BrowserSessions.current_reference(WebSession.browser_reference(activated)) == c_ref

    unknown =
      activate.(
        BrowserSessions.encode_reference(%{"id" => Ecto.UUID.generate(), "revision" => 1})
      )

    assert json_response(unknown, 401) == %{"error" => "invalid_authentication"}
  end

  test "the session gives the Console URL only to a site administrator", ctx do
    Repo.put_tenant_id(ctx.a.tenant_id)
    {:ok, _} = first_site_admin_fixture(ctx.a.uid)

    session =
      ctx.signed
      |> put_req_header("x-ankole-authentication", BrowserSessions.encode_reference(ctx.a_ref))
      |> get(ctx.origin <> "/.internal-apis/session")
      |> AnkoleWeb.InternalAPIContract.json_response(200)

    assert session["consoleURL"] == ctx.site_origin <> "/site-admin-console"
  end

  test "a chooser cannot use another tenant's proof or a revoked account", ctx do
    {shell, flow} = chooser(ctx.signed, ctx.tenant)
    foreign = Ankole.DataCase.create_tenant()
    {foreign_shell, foreign_flow} = chooser(ctx.signed, foreign)
    denied = select(foreign_shell, foreign, foreign_flow, ctx.a_ref)
    assert denied.status == 401

    unless @host_policy do
      assert select(shell, foreign, flow, ctx.a_ref).status == 401
    end

    Repo.put_tenant_id(ctx.a.tenant_id)
    assert {:ok, _} = BrowserSessions.revoke(WebSession.browser_reference(ctx.signed), ctx.a_ref)
    assert select(shell, ctx.tenant, flow, ctx.a_ref).status == 401
  end

  test "legacy HTTPS proof cookies migrate every verified account without changing the selection",
       ctx do
    old = send_resp(ctx.signed, 200, "")
    request = legacy_request(old, ctx.origin)
    migrated = get(request, ctx.origin <> "/")
    assert html_response(migrated, 200) =~ BrowserSessions.encode_reference(ctx.b_ref)
    assert WebSession.browser_reference(migrated) == WebSession.browser_reference(old)
    assert BrowserSessions.current_reference(WebSession.browser_reference(migrated)) == ctx.b_ref

    for ref <- [ctx.a_ref, ctx.b_ref] do
      assert migrated.resp_cookies[SessionCookies.authentication_prefix() <> ref["id"]].domain ==
               ctx.domain

      assert migrated.resp_cookies["__Host-ankole-auth-" <> ref["id"]].max_age == 0
    end

    assert migrated.resp_cookies["_ankole_key"].domain == ctx.domain
    assert migrated.resp_cookies["__Host-ankole"].max_age == 0
  end

  test "legacy migration cannot restore an account revoked before the request", ctx do
    old = send_resp(ctx.signed, 200, "")
    assert {:ok, _} = BrowserSessions.revoke(WebSession.browser_reference(old), ctx.a_ref)
    migrated = old |> legacy_request(ctx.origin) |> get(ctx.origin <> "/")
    assert html_response(migrated, 200) =~ BrowserSessions.encode_reference(ctx.b_ref)

    refute Map.has_key?(
             migrated.resp_cookies,
             SessionCookies.authentication_prefix() <> ctx.a_ref["id"]
           )

    assert migrated.resp_cookies["__Host-ankole-auth-" <> ctx.a_ref["id"]].max_age == 0
  end

  defp legacy_request(response, origin) do
    Enum.reduce(response.resp_cookies, build_conn(:get, origin <> "/"), fn {name, cookie}, conn ->
      legacy =
        if name == "_ankole_key",
          do: "__Host-ankole",
          else:
            String.replace_prefix(
              name,
              SessionCookies.authentication_prefix(),
              "__Host-ankole-auth-"
            )

      Plug.Test.put_req_cookie(conn, legacy, cookie.value)
    end)
  end

  defp login(conn, principal) do
    {:ok, conn, flow} = WebSession.begin_login(conn, :pod, %{})
    assert flow.mode == :add
    {:ok, _} = BrowserSessions.bind_provider(WebSession.browser_reference(conn), flow.id, "local")

    {:ok, conn, _} =
      WebSession.complete_login(conn, flow.id, %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "local",
        "external_id" => principal.uid
      })

    {conn, WebSession.authentication_reference(conn)}
  end

  defp chooser(conn, tenant) do
    {start, location} = begin_choice(conn, tenant)
    flow = URI.decode_query(URI.parse(location).query)["flow"]

    shell =
      start
      |> recycle()
      |> put_req_header("accept", "text/html")
      |> get(auth_origin(conn, tenant) <> location)

    assert html_response(shell, 200) =~ "csrf-token"
    {shell, flow}
  end

  defp begin_choice(conn, tenant) do
    if @host_policy do
      site = PodURL.site_origin(conn)
      account = conn |> put_req_header("accept", "text/html") |> get(site <> "/account")
      [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(account, 200))

      start =
        account
        |> recycle()
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-csrf-token", csrf)
        |> put_req_header("origin", site)
        |> post(site <> "/.internal-apis/saas/pod-login", %{
          slug: tenant.slug,
          return_to: "/content/space"
        })

      %{"returnTo" => location} = json_response(start, 200)
      {start, location}
    else
      start =
        get(
          conn,
          PodURL.origin(conn, tenant) <> "/sessions/new?switch=1&return_to=%2Fcontent%2Fspace"
        )

      {start, redirected_to(start)}
    end
  end

  defp select(shell, tenant, flow, ref) do
    [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, shell.resp_body)
    origin = auth_origin(shell, tenant)

    shell
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-csrf-token", csrf)
    |> put_req_header("origin", origin)
    |> post(origin <> "/.internal-apis/sessions/identity-selection", %{
      flow: flow,
      authenticationRef: BrowserSessions.encode_reference(ref)
    })
  end

  defp auth_origin(conn, tenant),
    do: if(@host_policy, do: PodURL.site_origin(conn), else: PodURL.origin(conn, tenant))
end
