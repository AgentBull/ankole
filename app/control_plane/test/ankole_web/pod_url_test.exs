defmodule AnkoleWeb.PodURLTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod

  alias Ankole.{Kernel, Repo}
  alias AnkoleWeb.PodURL

  @host_policy Application.compile_env(:ankole, :host_policy)

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok
  end

  test "the all-content scope remains a canonical browser path", ctx do
    assert {:ok, "/content/all?q=report"} = PodURL.path(get(ctx.conn, "/content/all?q=report"))
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
    assert html =~ entry_source(pod_entry())
    assert get_resp_header(rendered, "cache-control") == ["private, no-store"]

    full = rendered |> recycle() |> get("/conversations/#{chat}")

    assert redirected_to(full) ==
             PodURL.origin(conn, ctx.tenant) <> "/conversations/#{short_chat}"
  end

  test "a canonical slug login keeps its shared cookies and returns to the same deep Page", ctx do
    smtp = Ankole.Authn.SMTPFixture.start(self())
    on_exit(fn -> Ankole.Authn.SMTPFixture.stop(smtp) end)

    {:ok, _} =
      Ankole.AppConfigure.put_global_by_key("authn.email.mail", %{
        "server" => "127.0.0.1",
        "port" => smtp.port,
        "ssl" => true,
        "from" => "login@ankole.test",
        "cacertfile" => smtp.ca_path
      })

    Ankole.Authn.RateLimiter.reset_for_test()

    {:ok, %{principal: member}} =
      Ankole.Principals.create_human(%{
        display_name: "Deep link member",
        email: "deep-link@example.org"
      })

    path = "/pages/" <> Kernel.uuid_shorten(Kernel.gen_uuid_v7())
    conn = ctx.conn |> Map.put(:host, ctx.tenant.slug <> ".ankole.localhost") |> get(path)
    login = redirected_to(conn)
    login_uri = URI.parse(login)
    origin = PodURL.origin(conn, ctx.tenant)

    {shell, otp_origin, challenge_payload} =
      if @host_policy do
        assert String.starts_with?(login_uri.host, "accounts.")
        assert login_uri.path == "/sessions/new"

        assert URI.decode_query(login_uri.query) == %{
                 "tenant_id" => ctx.tenant.id,
                 "return_to" => path
               }

        shell = conn |> recycle() |> get(login)

        otp_origin =
          URI.to_string(%URI{
            scheme: login_uri.scheme,
            host: login_uri.host,
            port: login_uri.port
          })

        {shell, otp_origin,
         %{tenantID: ctx.tenant.id, returnTo: path, email: "deep-link@example.org"}}
      else
        assert login_uri.host in [nil, conn.host]
        assert login_uri.path == "/sessions/new"
        assert URI.decode_query(login_uri.query) == %{"return_to" => path}
        shell = conn |> recycle() |> Map.put(:host, conn.host) |> get(login)
        {shell, origin, %{returnTo: path, email: "deep-link@example.org"}}
      end

    html = html_response(shell, 200)
    assert html =~ entry_source("auth")

    assert Enum.any?(
             get_resp_header(shell, "set-cookie"),
             &String.contains?(String.downcase(&1), "domain=ankole.localhost")
           )

    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html)
    otp_uri = URI.parse(otp_origin)

    sent =
      shell
      |> recycle()
      |> Map.merge(%{
        host: otp_uri.host,
        port: otp_uri.port,
        scheme: String.to_existing_atom(otp_uri.scheme)
      })
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("origin", otp_origin)
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", challenge_payload)

    challenge = api_response(sent, 201)["challengeID"]
    assert_receive {:smtp_message, _, ["deep-link@example.org"], message}, 5_000
    [_, code] = Regex.run(~r/code is (\d{6})/, Ankole.Authn.SMTPFixture.text(message))

    # The same browser cookie and valid code cannot move a login to another Pod.
    foreign = Ankole.DataCase.create_tenant()

    denied =
      sent
      |> recycle()
      |> pod_conn(foreign)
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("origin", PodURL.origin(conn, foreign))
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    assert denied.status == 401

    verified =
      sent
      |> recycle()
      |> Map.merge(%{
        host: otp_uri.host,
        port: otp_uri.port,
        scheme: String.to_existing_atom(otp_uri.scheme)
      })
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("origin", otp_origin)
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        challengeID: challenge,
        code: code
      })

    return_to = origin <> path
    assert %{"returnTo" => ^return_to} = api_response(verified, 201)

    rendered = verified |> recycle() |> delete_req_header("accept") |> get(return_to)
    assert html_response(rendered, 200) =~ entry_source(pod_entry())

    assert %{"principal_uid" => uid, "tenant_id" => tenant_id} =
             AnkoleWeb.Session.pod_session(rendered)

    assert uid == member.uid
    assert tenant_id == ctx.tenant.id
  end

  test "unknown tenants and noncanonical short UUID aliases fail closed", ctx do
    unknown =
      ctx.conn |> Map.put(:host, "missing-#{Kernel.gen_uuid()}.ankole.localhost") |> get("/")

    assert response(unknown, if(@host_policy, do: 400, else: 404))

    for {host, path} <- [
          {ctx.tenant.slug <> ".ankole.localhost", "/pages/AAAAAAAAAAAAAAAAAAAAAB"},
          {ctx.tenant.slug <> ".ankole.localhost", "/conversations/not-a-uuid"}
        ] do
      assert ctx.conn |> Map.put(:host, host) |> get(path) |> response(404)
    end
  end

  test "inactive tenants reject both slug hosts and explicit Pod IDs" do
    for field <- [:suspended_at, :deleting_at] do
      tenant = Ankole.DataCase.create_tenant()
      Repo.update!(Ecto.Changeset.change(tenant, %{field => DateTime.utc_now()}))

      assert :error =
               AnkoleWeb.Plugs.RequestHost.classify_uri(
                 URI.parse("http://#{tenant.slug}.ankole.localhost")
               )

      Repo.without_tenant(fn ->
        conn = put_req_header(build_conn(), "x-ankole-pod", tenant.id)
        assert {:error, :not_found} = AnkoleWeb.Plugs.RequirePodSession.target_tenant(conn)
      end)
    end
  end

  test "unknown content scopes retain the shell's safe Space fallback", ctx do
    {conn, _uid} =
      active_admin_conn_with_principal(%{ctx.conn | host: ctx.tenant.slug <> ".ankole.localhost"})

    for scope <- ~w(constructor toString __proto__) do
      response = get(conn, "/content/" <> scope)
      target = PodURL.origin(conn, ctx.tenant) <> "/content/space"
      assert redirected_to(response) == target

      assert response |> recycle() |> get(target) |> html_response(200) =~
               entry_source(pod_entry())
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
      denied = api_get(conn, "/api/v2/pod/pages", query)
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(denied, 401)
    end

    Repo.put_tenant_id(ctx.tenant.id)

    assert AnkoleWeb.Plugs.RequestHost.classify_uri(
             URI.parse("http://#{ctx.tenant.slug}.ankole.localhost:4000")
           ) ==
             {:ok, {:pod, ctx.tenant.id}}
  end

  test "an OIDC authorization request cannot render on another tenant's host even with its proof cookies",
       ctx do
    foreign = Ankole.DataCase.create_tenant()

    {:ok, %{client: client}} =
      Ankole.OIDC.create_client(%{
        name: "Pod host binding RP",
        type: "public",
        enabled: true,
        redirect_uris: ["https://rp.example.test/callback"],
        scopes: ["openid"]
      })

    conn =
      ctx.conn
      |> Map.put(:host, ctx.tenant.slug <> ".ankole.localhost")
      |> init_test_session(%{})
      |> AnkoleWeb.Session.ensure_browser()

    {:ok, request} =
      Ankole.OIDC.AuthorizationRequests.begin(
        AnkoleWeb.Session.browser_reference(conn),
        client.id,
        %{"client_id" => client.id, "scope" => "openid"}
      )

    denied =
      conn
      |> recycle()
      |> Map.put(:host, foreign.slug <> ".ankole.localhost")
      |> get("/sessions/new?oauth_request=" <> request.id)

    assert html_response(denied, 401) =~ entry_source("auth")
  end

  if @host_policy do
    test "noncanonical local entries reject before creating browser cookies" do
      for path <- [
            "/",
            "/setup",
            "/site-admin-console",
            "/sessions/new?return_to=%2Fcontent%2Fspace",
            "/sessions/new?oauth_request=old-bound-request",
            "/api/v2/pod/agents"
          ] do
        response = get(build_conn(), "http://127.0.0.1:4002" <> path)
        assert response(response, 400) == "Invalid host"
        assert get_resp_header(response, "location") == []
        assert response.resp_cookies == %{}
      end
    end
  else
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
        get(
          build_conn(),
          "http://ankole.localhost:4002/sessions/new?return_to=%2Fcontent%2Fspace"
        )

      destination = redirected_to(redirected)
      assert URI.parse(destination).host == ctx.tenant.slug <> ".ankole.localhost"
      login = get(build_conn(), destination)
      assert html_response(login, 200) =~ entry_source("auth")
      assert login.resp_cookies["_ankole_key"].domain == "ankole.localhost"

      stale =
        get(build_conn(), "http://127.0.0.1:4002/sessions/new?oauth_request=old-bound-request")

      assert response(stale, 401) =~ "sign-in address changed"
      assert get_resp_header(stale, "location") == []
      api = get(build_conn(), "http://127.0.0.1:4002/api/v2/pod/agents")
      assert api.status == 401
      assert get_resp_header(api, "location") == []
    end
  end

  defp pod_entry, do: if(@host_policy, do: "saas-pod", else: "pod")

  defp entry_source(entry) do
    source = Application.fetch_env!(:ankole, :webapp_entries) |> Map.fetch!(entry)
    "http://assets.test/#{String.trim_leading(source, "/")}"
  end
end
