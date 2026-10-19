defmodule AnkoleWeb.BrowserAuthenticationsTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.BrowserSessions
  alias Ankole.Repo
  alias AnkoleWeb.Session, as: WebSession

  setup %{tenant: tenant, conn: conn} do
    allow_cache_database_access()
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.Setup.Config.put_completed(true)
    %{principal: a} = human_fixture()
    %{principal: b} = human_fixture()
    {:ok, a: a, b: b, conn: %{conn | host: tenant.slug <> ".ankole.localhost"}}
  end

  test "a browser grouping reference and an identity hint are insufficient without the authentication cookie",
       %{conn: conn, a: a} do
    {signed_in, reference} = add_login(conn |> init_test_session(%{}), a)
    group = WebSession.browser_reference(signed_in)

    response =
      build_conn()
      |> init_test_session(%{browser_session: group})
      |> put_req_header("x-ankole-authentication", BrowserSessions.encode_reference(reference))
      |> get("/.internal-apis/session")

    assert %{"authenticated" => false} =
             AnkoleWeb.InternalAPIContract.json_response(response, 401)
  end

  test "logging in B preserves A's CSRF proof, and a single exit leaves B usable", %{
    conn: conn,
    tenant: tenant,
    a: a,
    b: b
  } do
    {conn, a_ref} = add_login(conn |> init_test_session(%{}), a)
    a_page = get(conn, "/")
    a_token = csrf(a_page)

    {conn, b_ref} =
      Repo.with_tenant(tenant.id, fn ->
        a_page |> recycle() |> init_test_session(get_session(a_page)) |> add_login(b)
      end)

    b_page = get(conn, "/")
    b_token = csrf(b_page)
    assert a_token != b_token

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      b_page
      |> delete_request(a_ref, b_token)
      |> delete("/.internal-apis/authentications/current")
    end

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      b_page
      |> delete_request(a_ref, a_token)
      |> put_req_header("origin", "http://other-pod.example.com")
      |> delete("/.internal-apis/authentications/current")
    end

    ended =
      b_page
      |> delete_request(a_ref, a_token)
      |> delete("/.internal-apis/authentications/current")

    assert %{"ok" => true} = AnkoleWeb.InternalAPIContract.json_response(ended, 200)
    assert current(ended, b_ref)["principalUID"] == b.uid
    stale = ended |> recycle() |> pin(a_ref) |> get("/.internal-apis/session")
    assert %{"authenticated" => false} = AnkoleWeb.InternalAPIContract.json_response(stale, 401)
  end

  test "a late A cookie rejects only A and does not replace B", %{
    conn: conn,
    tenant: tenant,
    a: a,
    b: b
  } do
    {conn, first_a} = add_login(conn |> init_test_session(%{}), a)
    [name] = Map.keys(conn.resp_cookies)
    stale_ciphertext = conn.resp_cookies[name].value
    {conn, b_ref} = add_login(conn, b)
    page = get(conn, "/")

    {conn, current_a} =
      Repo.with_tenant(tenant.id, fn ->
        page |> recycle() |> init_test_session(get_session(page)) |> add_login(a)
      end)

    renewed = get(conn, "/")
    refute first_a == current_a

    stale =
      renewed
      |> recycle()
      |> Plug.Test.put_req_cookie(name, stale_ciphertext)
      |> pin(current_a)
      |> get("/.internal-apis/session")

    assert %{"authenticated" => false} = AnkoleWeb.InternalAPIContract.json_response(stale, 401)
    assert current(stale, b_ref)["principalUID"] == b.uid
  end

  test "unknown explicit API references fail without falling back to the active identity", %{
    conn: conn,
    a: a
  } do
    {conn, _} = add_login(conn |> init_test_session(%{}), a)
    page = get(conn, "/")

    response =
      page
      |> recycle()
      |> put_req_header("x-ankole-authentication", Ecto.UUID.generate() <> ".1")
      |> get("/.internal-apis/session")

    assert %{"authenticated" => false} =
             AnkoleWeb.InternalAPIContract.json_response(response, 401)

    response =
      page |> recycle() |> get("/.internal-apis/session", %{"authentication_ref" => "foreign"})

    assert %{"authenticated" => false} =
             AnkoleWeb.InternalAPIContract.json_response(response, 401)
  end

  test "a complete late login response cannot undo browser logout or displace the next account",
       %{a: a, b: b, tenant: tenant} do
    initial = browser_request(%{}) |> WebSession.ensure_browser() |> send_resp(200, "")
    cookies = apply_cookies(%{}, initial)
    browser = WebSession.browser_reference(initial)

    {a_login, a_ref} = add_login(browser_request(cookies), a)
    delayed_a = send_resp(a_login, 200, "")
    assert length(get_resp_header(delayed_a, "set-cookie")) == 2

    {:ok, signed_out} = cookies |> browser_request() |> WebSession.logout()
    cookies = apply_cookies(cookies, send_resp(signed_out, 200, ""))

    {b_login, b_ref} = add_login(browser_request(cookies), b)
    assert WebSession.browser_reference(b_login) == browser
    cookies = apply_cookies(cookies, send_resp(b_login, 200, ""))
    cookies = apply_cookies(cookies, delayed_a)

    b_response = cookies |> api_request(b_ref) |> get("/.internal-apis/session")
    assert AnkoleWeb.InternalAPIContract.json_response(b_response, 200)["principalUID"] == b.uid

    a_response = cookies |> api_request(a_ref) |> get("/.internal-apis/session")

    assert %{"authenticated" => false} =
             AnkoleWeb.InternalAPIContract.json_response(a_response, 401)

    Repo.put_tenant_id(tenant.id)
    assert {:error, :browser_session_expired} = BrowserSessions.get_authentication(a_ref)
    assert {:ok, _} = BrowserSessions.get_authentication(b_ref)
  end

  test "a pinned Pod proof reads only its account and still observes revocation", %{
    a: a,
    b: b,
    tenant: tenant
  } do
    {a_login, a_ref} = add_login(browser_request(%{}), a)
    cookies_a = apply_cookies(%{}, send_resp(a_login, 200, ""))
    {b_login, b_ref} = add_login(browser_request(cookies_a), b)
    cookies_both = apply_cookies(cookies_a, send_resp(b_login, 200, ""))

    pinned_a = cookies_a |> browser_request() |> pin(a_ref)
    pinned_both = cookies_both |> browser_request() |> pin(a_ref)
    {identity, reads_a} = authentication_reads(fn -> WebSession.pod_session(pinned_a) end)
    assert identity["principal_uid"] == a.uid
    {identity, reads_both} = authentication_reads(fn -> WebSession.pod_session(pinned_both) end)
    assert identity["principal_uid"] == a.uid
    assert reads_a > 0
    assert reads_both == reads_a

    browser = WebSession.browser_reference(b_login)
    {:ok, _} = BrowserSessions.activate(browser, b_ref, tenant.id)
    assert WebSession.pod_session(pinned_both)["principal_uid"] == a.uid
    {:ok, _} = BrowserSessions.revoke(browser, a_ref)
    refute WebSession.pod_session(pinned_both)
    assert WebSession.pod_session(pin(pinned_both, b_ref))["principal_uid"] == b.uid
  end

  test "a file subresource retains its document identity when another account becomes active", %{
    a: a,
    b: b,
    tenant: tenant
  } do
    {:ok, page} = Ankole.Pod.Pages.create(a.uid, %{type: "file", private_owner_uid: a.uid})

    {:ok, uploaded} =
      Ankole.Pod.Files.upload(
        a.uid,
        page.id,
        "file",
        0,
        "report.pdf",
        "account A report",
        "application/pdf"
      )

    {a_login, a_ref} = add_login(browser_request(%{}), a)
    cookies_a = apply_cookies(%{}, send_resp(a_login, 200, ""))
    {b_login, b_ref} = add_login(browser_request(cookies_a), b)
    cookies_both = apply_cookies(cookies_a, send_resp(b_login, 200, ""))
    {:ok, _} = BrowserSessions.activate(WebSession.browser_reference(b_login), b_ref, tenant.id)
    path = "/.internal-apis/pod/pages/#{page.id}/files/content"

    params = %{
      path: "report.pdf",
      sha256: uploaded.file.sha256,
      authentication_ref: BrowserSessions.encode_reference(a_ref)
    }

    response = cookies_both |> unpinned_request() |> get(path, params)
    assert response(response, 200) == "account A report"
    assert get_resp_header(response, "cache-control") == ["private, no-cache"]

    denied =
      cookies_both |> unpinned_request() |> get(path, Map.delete(params, :authentication_ref))

    assert %{"error" => %{"code" => "forbidden"}} = json_response(denied, 403)

    unrelated =
      cookies_both
      |> unpinned_request()
      |> get("/.internal-apis/pod/pages/#{page.id}/files", %{
        authentication_ref: params.authentication_ref
      })

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(unrelated, 401)

    {:ok, _} = BrowserSessions.revoke(WebSession.browser_reference(b_login), a_ref)
    revoked = cookies_both |> unpinned_request() |> get(path, params)
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(revoked, 401)
  end

  test "a file URL reference requires its own proof cookie and the same browser group", %{
    a: a,
    b: b
  } do
    {:ok, page} = Ankole.Pod.Pages.create(a.uid, %{type: "file", private_owner_uid: a.uid})

    {:ok, _} =
      Ankole.Pod.Files.upload(
        a.uid,
        page.id,
        "file",
        0,
        "report.pdf",
        "private A",
        "application/pdf"
      )

    {a_login, a_ref} = add_login(browser_request(%{}), a)
    cookies_a = apply_cookies(%{}, send_resp(a_login, 200, ""))

    {proof_name, proof} =
      Enum.find(cookies_a, fn {name, _value} -> String.ends_with?(name, a_ref["id"]) end)

    path = "/.internal-apis/pod/pages/#{page.id}/files/content"
    params = %{path: "report.pdf", authentication_ref: BrowserSessions.encode_reference(a_ref)}

    missing = cookies_a |> Map.delete(proof_name) |> unpinned_request() |> get(path, params)
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(missing, 401)

    {b_login, _b_ref} = add_login(browser_request(%{}), b)

    foreign_cookies =
      %{} |> apply_cookies(send_resp(b_login, 200, "")) |> Map.put(proof_name, proof)

    foreign = foreign_cookies |> unpinned_request() |> get(path, params)
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(foreign, 401)
  end

  defp browser_request(cookies) do
    cookies
    |> Enum.reduce(build_conn(), fn {name, value}, conn ->
      Plug.Test.put_req_cookie(conn, name, value)
    end)
    |> Map.put(:secret_key_base, AnkoleWeb.Endpoint.config(:secret_key_base))
    |> Plug.Session.call(
      Plug.Session.init(
        store: AnkoleWeb.SessionCookieStore,
        key: "_ankole_key",
        key_context: "_ankole_key",
        max_age: 86_400
      )
    )
    |> fetch_session()
  end

  defp apply_cookies(cookies, response) do
    Enum.reduce(get_resp_header(response, "set-cookie"), cookies, fn header, cookies ->
      [pair | _attributes] = String.split(header, ";")
      [name, value] = String.split(pair, "=", parts: 2)
      if value == "", do: Map.delete(cookies, name), else: Map.put(cookies, name, value)
    end)
  end

  defp api_request(cookies, ref) do
    cookies
    |> unpinned_request()
    |> pin(ref)
  end

  defp unpinned_request(cookies),
    do:
      Enum.reduce(cookies, build_conn(), fn {name, value}, conn ->
        Plug.Test.put_req_cookie(conn, name, value)
      end)

  defp authentication_reads(read) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        &__MODULE__.capture_authentication_read/4,
        {self(), handler}
      )

    try do
      {read.(), count_reads(handler, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  def capture_authentication_read(_event, _measurements, metadata, {owner, handler}) do
    if self() == owner and metadata.source == "browser_authentications",
      do: send(owner, {:authentication_read, handler})
  end

  defp count_reads(handler, count) do
    receive do
      {:authentication_read, ^handler} -> count_reads(handler, count + 1)
    after
      0 -> count
    end
  end

  defp add_login(conn, principal) do
    {:ok, conn, transaction} = WebSession.begin_login(conn, :pod, %{}, mode: :add)

    {:ok, _} =
      BrowserSessions.bind_provider(WebSession.browser_reference(conn), transaction.id, "local")

    {:ok, conn, _} =
      WebSession.complete_login(conn, transaction.id, %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "local",
        "external_id" => principal.uid,
        "auth_time" => System.system_time(:second)
      })

    {conn, WebSession.authentication_reference(conn)}
  end

  defp current(conn, ref),
    do:
      conn
      |> recycle()
      |> pin(ref)
      |> get("/.internal-apis/session")
      |> AnkoleWeb.InternalAPIContract.json_response(200)

  defp pin(conn, ref),
    do: put_req_header(conn, "x-ankole-authentication", BrowserSessions.encode_reference(ref))

  defp csrf(conn) do
    [_, token] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, conn.resp_body)
    token
  end

  defp delete_request(conn, ref, token) do
    conn
    |> recycle()
    |> pin(ref)
    |> put_private(:plug_skip_csrf_protection, false)
    |> put_req_header(
      "origin",
      URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})
    )
    |> put_req_header("x-csrf-token", token)
  end
end
