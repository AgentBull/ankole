defmodule AnkoleWeb.PodURLTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.{Kernel, Repo}
  alias AnkoleWeb.PodURL

  setup %{tenant: tenant} do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.Setup.Config.put_completed(true)
    :ok
  end

  test "legacy and full UUID links redirect once to the slug host and short browser IDs", ctx do
    page = Kernel.gen_uuid_v7()
    chat = Kernel.gen_uuid_v7()
    short_page = Kernel.uuid_shorten(page)
    short_chat = Kernel.uuid_shorten(chat)
    {conn, _uid} = active_admin_conn_with_principal(ctx.conn)

    legacy = get(conn, "/pod/pages/#{page}?tenant_id=#{ctx.tenant.id}&chat=#{chat}")
    canonical = PodURL.origin(conn, ctx.tenant) <> "/pages/#{short_page}?chat=#{short_chat}"
    assert redirected_to(legacy) == canonical

    rendered =
      legacy
      |> recycle()
      |> Map.put(:host, ctx.tenant.slug <> ".ankole.localhost")
      |> get(canonical)

    html = html_response(rendered, 200)
    assert html =~ ~s(name="ankole-pod" content="#{ctx.tenant.id}")
    assert html =~ ~s(http://assets.test/entrypoints/pod.tsx)
    assert get_resp_header(rendered, "cache-control") == ["private, no-store"]

    full = rendered |> recycle() |> get("/conversations/#{chat}")

    assert redirected_to(full) ==
             PodURL.origin(conn, ctx.tenant) <> "/conversations/#{short_chat}"
  end

  test "a canonical slug entry starts login on that host and returns to the same Page", ctx do
    path = "/pages/" <> Kernel.uuid_shorten(Kernel.gen_uuid_v7())
    conn = ctx.conn |> Map.put(:host, ctx.tenant.slug <> ".ankole.localhost") |> get(path)
    login = redirected_to(conn)
    assert login =~ "/sessions/new?flow="
    flow = login |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("flow")

    assert {:ok, %{tenant_id: id, request: %{"return_to" => ^path}}} =
             AnkoleWeb.Session.login_transaction(conn, flow)

    assert id == ctx.tenant.id
    assert conn |> recycle() |> get(login) |> html_response(200) =~ "entrypoints/auth.tsx"

    assert Enum.any?(
             get_resp_header(conn, "set-cookie"),
             &String.contains?(String.downcase(&1), "domain=ankole.localhost")
           )
  end

  test "unknown tenants and noncanonical short UUID aliases fail closed", ctx do
    for {host, path} <- [
          {"missing-#{Kernel.gen_uuid()}.ankole.localhost", "/"},
          {ctx.tenant.slug <> ".ankole.localhost", "/pages/AAAAAAAAAAAAAAAAAAAAAB"},
          {ctx.tenant.slug <> ".ankole.localhost", "/conversations/not-a-uuid"}
        ] do
      assert ctx.conn |> Map.put(:host, host) |> get(path) |> response(404)
    end
  end

  test "unknown content scopes retain the shell's safe Space fallback", ctx do
    {conn, _uid} =
      active_admin_conn_with_principal(%{ctx.conn | host: ctx.tenant.slug <> ".ankole.localhost"})

    for scope <- ~w(constructor toString __proto__) do
      response = get(conn, "/content/" <> scope)
      target = PodURL.origin(conn, ctx.tenant) <> "/content/space"
      assert redirected_to(response) == target
      assert response |> recycle() |> get(target) |> html_response(200) =~ "entrypoints/pod.tsx"
    end
  end

  test "a tenant Host cannot be replaced by a different durable tenant header or query", ctx do
    foreign = Ankole.DataCase.create_tenant()

    {conn, _uid} =
      active_admin_conn_with_principal(%{ctx.conn | host: ctx.tenant.slug <> ".ankole.localhost"})

    for proof <- [:header, :query] do
      conn = recycle(conn)
      conn = if proof == :header, do: put_req_header(conn, "x-ankole-pod", foreign.id), else: conn
      query = if proof == :query, do: %{tenant_id: foreign.id}, else: %{}
      denied = get(conn, "/.internal-apis/pod/pages", query)
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(denied, 401)
    end

    Repo.put_tenant_id(ctx.tenant.id)

    assert PodURL.local_host(URI.parse("http://#{ctx.tenant.slug}.ankole.localhost:4000")) ==
             {:ok, {:pod, ctx.tenant.id}}
  end

  test "a login flow cannot render on another tenant's host even with its proof cookies", ctx do
    foreign = Ankole.DataCase.create_tenant()
    conn = ctx.conn |> Map.put(:host, ctx.tenant.slug <> ".ankole.localhost") |> get("/")
    login = redirected_to(conn)

    denied =
      conn |> recycle() |> Map.put(:host, foreign.slug <> ".ankole.localhost") |> get(login)

    assert html_response(denied, 401) =~ "entrypoints/auth.tsx"
  end

  test "known local browser entries canonicalize before creating shared login cookies", ctx do
    for path <- [
          "/",
          "/setup",
          "/site-admin-console",
          "/sessions/new?return_to=%2Fcontent%2Fspace"
        ] do
      response = get(build_conn(), "http://127.0.0.1:4002" <> path)
      assert redirected_to(response) == "http://ankole.localhost:4002" <> path
      assert response.resp_cookies == %{}
    end

    redirected =
      get(build_conn(), "http://ankole.localhost:4002/sessions/new?return_to=%2Fcontent%2Fspace")

    destination = redirected_to(redirected)
    assert URI.parse(destination).host == ctx.tenant.slug <> ".ankole.localhost"
    login = get(build_conn(), destination)
    assert redirected_to(login) =~ "/sessions/new?flow="
    assert login.resp_cookies["_ankole_key"].domain == "ankole.localhost"

    stale = get(build_conn(), "http://127.0.0.1:4002/sessions/new?flow=old-bound-flow")
    assert response(stale, 401) =~ "sign-in address changed"
    assert get_resp_header(stale, "location") == []
    api = get(build_conn(), "http://127.0.0.1:4002/.internal-apis/pod/agents")
    assert api.status == 401
    assert get_resp_header(api, "location") == []
  end
end
