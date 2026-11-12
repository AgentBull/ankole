defmodule AnkoleWeb.OIDCDesktopPodTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.OIDC
  alias Ankole.OIDC.DesktopClient
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.PodSocket
  alias AnkoleWeb.Session, as: WebSession

  setup %{tenant: tenant} do
    Ankole.AppConfigure.Registry.clear_for_test()
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "lark-desktop-test",
        "lark",
        %{"appID" => "cli_desktop_fixture", "appSecret" => "secret"},
        true
      )

    :ok
  end

  test "GET /.well-known/ankole-desktop provisions the deterministic PKCE client and honors administrator disablement",
       %{conn: conn, tenant: tenant} do
    expected_id = DesktopClient.client_id(tenant.id)

    first =
      conn
      |> pod_conn(tenant)
      |> get("/.well-known/ankole-desktop")
      |> json_response(200)

    second =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> get("/.well-known/ankole-desktop")
      |> json_response(200)

    assert first == second
    assert first["client_id"] == expected_id
    assert first["redirect_uri"] == "ankole://oauth/callback"
    assert "pod" in first["scopes_supported"]
    assert "offline_access" in first["scopes_supported"]

    {:ok, _disabled} = OIDC.update_client(expected_id, %{enabled: false})

    disabled_resp =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> get("/.well-known/ankole-desktop")
      |> json_response(403)

    assert disabled_resp["error"] == "desktop_client_disabled"
  end

  test "PKCE desktop Bearer token authenticates Pod APIs, bootstrap, session, and PodSocket without cookies or CSRF",
       %{conn: conn, tenant: tenant} do
    human =
      human_fixture(%{
        uid: unique_uid("desktop-human"),
        display_name: "Desktop Member",
        email: "#{unique_uid("desktop-human")}@example.com"
      })

    discovery =
      conn
      |> pod_conn(tenant)
      |> get("/.well-known/ankole-desktop")
      |> json_response(200)

    client_id = discovery["client_id"]
    verifier = String.duplicate("v", 43)

    code =
      authorize_desktop_code!(
        conn,
        tenant,
        human.principal.uid,
        client_id,
        "ankole://oauth/callback",
        "openid profile email pod offline_access",
        verifier
      )

    token_resp =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client_id,
        "redirect_uri" => "ankole://oauth/callback",
        "code" => code,
        "code_verifier" => verifier
      })
      |> json_response(200)

    access_token = token_resp["access_token"]
    assert is_binary(access_token)
    assert is_binary(token_resp["refresh_token"])

    bootstrap =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/api/v2/pod/bootstrap")
      |> json_response(200)

    assert bootstrap["tenantId"] == tenant.id
    assert bootstrap["tenantSlug"] == tenant.slug
    assert bootstrap["principalUid"] == human.principal.uid
    assert bootstrap["authenticationRef"] == "oauth"

    realtime =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/api/v2/pod/realtime-token")
      |> json_response(200)

    assert is_binary(realtime["token"])
    assert realtime["principal"]["uid"] == human.principal.uid

    versions =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post("/api/v2/pod/versions", %{"data" => %{"pages" => [], "tables" => []}})
      |> json_response(201)

    assert versions == %{"pages" => [], "tables" => []}

    assert PodSocket.check_origin?(URI.parse("tauri://localhost"))
    assert PodSocket.check_origin?(URI.parse("http://tauri.localhost"))
    assert PodSocket.check_origin?(URI.parse("https://tauri.localhost"))

    pod_uri = URI.parse(AnkoleWeb.PodURL.origin(conn, tenant) <> "/pod/socket/websocket")

    assert {:ok, socket} =
             PodSocket.connect(
               %{"token" => realtime["token"]},
               %Phoenix.Socket{},
               %{peer_data: %{address: {127, 0, 0, 1}}, uri: pod_uri, x_headers: []}
             )

    assert socket.assigns.uid == human.principal.uid
    assert socket.assigns.tenant_id == tenant.id

    browser_session =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/api/v2/browser/session")
      |> json_response(200)

    assert browser_session["authenticated"] == true
    assert browser_session["principalUID"] == human.principal.uid
    assert Enum.any?(browser_session["accounts"], &(&1["tenant"]["id"] == tenant.id))

    # Strict non-fallback: an invalid Authorization header must reject even when a valid cookie exists.
    cookie_conn = oauth_session_conn(recycle(conn), tenant, human.principal.uid)

    rejected =
      cookie_conn
      |> put_req_header("authorization", "Bearer forged-invalid-token")
      |> get("/api/v2/pod/bootstrap")
      |> json_response(401)

    assert rejected["error"]["code"] == "unauthorized"
  end

  test "OIDC access tokens without the pod scope are rejected on Pod endpoints",
       %{conn: conn, tenant: tenant} do
    human =
      human_fixture(%{
        uid: unique_uid("no-pod-scope"),
        display_name: "Scoped Member",
        email: "#{unique_uid("no-pod-scope")}@example.com"
      })

    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Profile Only RP",
        enabled: true,
        type: "public",
        redirect_uris: ["https://rp.example.test/callback"],
        scopes: ["openid", "profile"],
        allowed_group_ids: [],
        allowed_models: %{}
      })

    verifier = String.duplicate("p", 43)

    code =
      authorize_desktop_code!(
        conn,
        tenant,
        human.principal.uid,
        client.id,
        "https://rp.example.test/callback",
        "openid profile",
        verifier
      )

    token_resp =
      conn
      |> recycle()
      |> pod_conn(tenant)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => "https://rp.example.test/callback",
        "code" => code,
        "code_verifier" => verifier
      })
      |> json_response(200)

    conn
    |> recycle()
    |> pod_conn(tenant)
    |> put_req_header("authorization", "Bearer #{token_resp["access_token"]}")
    |> get("/api/v2/pod/bootstrap")
    |> json_response(401)
  end

  test "Web App Manifest is injected exclusively on the Pod shell and omitted from setup, auth, and console",
       %{conn: conn, tenant: tenant} do
    human =
      human_fixture(%{
        uid: unique_uid("pwa-admin"),
        display_name: "PWA Admin",
        email: "#{unique_uid("pwa-admin")}@example.com"
      })

    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(human.principal.uid)

    authed_pod = oauth_session_conn(conn, tenant, human.principal.uid)
    pod_html = authed_pod |> get("/") |> html_response(200)

    assert pod_html =~
             ~s(<link rel="manifest" href="/pod/manifest.webmanifest" crossorigin="use-credentials">)

    manifest_conn =
      authed_pod |> recycle() |> pod_conn(tenant) |> get("/pod/manifest.webmanifest")

    assert get_resp_header(manifest_conn, "content-type") |> hd() =~ "application/manifest+json"
    manifest = json_response(manifest_conn, 200)
    assert manifest["display"] == "standalone"
    assert manifest["start_url"] == "/"
    assert Enum.any?(manifest["icons"], &(&1["src"] == "/images/pwa-192.png"))
    assert Enum.any?(manifest["icons"], &(&1["src"] == "/images/pwa-512.png"))

    auth_conn = conn |> recycle() |> pod_conn(tenant) |> get("/sessions/new")

    auth_html =
      case get_resp_header(auth_conn, "location") do
        [target] -> conn |> recycle() |> get(target) |> html_response(200)
        [] -> html_response(auth_conn, 200)
      end

    refute auth_html =~ "manifest.webmanifest"

    console_html =
      authed_pod
      |> get(console_url("/"))
      |> html_response(200)

    refute console_html =~ "manifest.webmanifest"
  end

  defp authorize_desktop_code!(
         conn,
         tenant,
         principal_uid,
         client_id,
         redirect_uri,
         scope,
         verifier
       ) do
    authorization =
      conn
      |> recycle()
      |> oauth_session_conn(tenant, principal_uid)
      |> get("/oauth/authorize", %{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "scope" => scope,
        "state" => "desktop-state-1",
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256"
      })

    query =
      authorization
      |> redirected_to(302)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query["state"] == "desktop-state-1"
    assert is_binary(query["code"])
    query["code"]
  end

  defp oauth_session_conn(conn, tenant, principal_uid) do
    conn =
      conn
      |> pod_conn(tenant)
      |> init_test_session(%{})
      |> WebSession.ensure_browser()

    {:ok, version} = Ankole.Principals.HumanAccess.current_version(principal_uid)

    {:ok, %{browser: browser, authentication: authentication}} =
      Ankole.BrowserSessions.authenticate(
        WebSession.browser_reference(conn),
        %{
          "principal_uid" => principal_uid,
          "provider_id" => "lark-desktop-test",
          "external_id" => principal_uid,
          "access_version" => version,
          "auth_time" => System.system_time(:second)
        }
      )

    WebSession.put_authentication(conn, browser, authentication)
  end

  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end
end
