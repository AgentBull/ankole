defmodule AnkoleWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  @endpoint AnkoleWeb.Endpoint

  use AnkoleWeb, :verified_routes

  import Plug.Conn
  import Phoenix.ConnTest, except: [build_conn: 0, recycle: 1, recycle: 2]

  alias Ankole.PrincipalsFixtures
  alias AnkoleWeb.Session, as: WebSession

  using do
    quote do
      @endpoint AnkoleWeb.Endpoint

      use AnkoleWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest, except: [build_conn: 0, recycle: 1, recycle: 2]
      import AnkoleWeb.ConnCase
    end
  end

  setup tags do
    Ankole.DataCase.setup_sandbox(tags)
    tenant = Ankole.DataCase.create_tenant()
    # Fixtures use this tenant; Endpoint.ResetTenant resets it for each request.
    Ankole.Repo.put_tenant_id(tenant.id)
    conn = build_conn() |> assign(:test_tenant, tenant)

    conn =
      case Map.get(tags, :host, :site) do
        :site -> conn
        :pod -> pod_conn(conn, tenant)
      end

    {:ok, tenant: tenant, conn: conn}
  end

  @doc "Builds an unauthenticated connection at the site's canonical origin."
  def build_conn, do: site_conn(Phoenix.ConnTest.build_conn())

  @doc "Recycles browser state and selected headers at the connection's current origin."
  def recycle(conn, headers \\ ~w(accept accept-language authorization)) do
    conn
    |> Phoenix.ConnTest.recycle(headers)
    |> Map.merge(%{scheme: conn.scheme, port: conn.port})
  end

  @doc "Uses the site's canonical origin for Console and public API requests."
  def site_conn(conn), do: at_origin(conn, AnkoleWeb.PodURL.site_origin(conn))

  @doc "Uses the tenant's canonical origin for Pod requests."
  def pod_conn(conn, tenant), do: at_origin(conn, AnkoleWeb.PodURL.origin(conn, tenant))

  @doc "Sets a canonical HTTPS site behind a proxy for a synchronous controller test."
  def forwarded_https_conn(conn) do
    previous = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)
    url = Keyword.merge(AnkoleWeb.Endpoint.config(:url), scheme: "https", port: 443)
    configured = Keyword.put(previous, :url, url)
    Application.put_env(:ankole, AnkoleWeb.Endpoint, configured)

    AnkoleWeb.Endpoint.config_change(
      [{AnkoleWeb.Endpoint, configured}],
      []
    )

    on_exit(fn ->
      Application.put_env(:ankole, AnkoleWeb.Endpoint, previous)
      AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, previous}], [])
    end)

    %{conn | scheme: :https, port: 443}
    |> then(&at_origin(&1, AnkoleWeb.PodURL.site_origin(&1)))
    |> Map.merge(%{scheme: :http, port: 80})
    |> put_req_header("x-forwarded-proto", "https")
  end

  defp at_origin(conn, origin) do
    uri = URI.parse(origin)
    %{conn | host: uri.host, port: uri.port, scheme: String.to_existing_atom(uri.scheme)}
  end

  @doc "Adds a WebSocket handshake for the connection's selected origin."
  def websocket_upgrade_headers(conn) do
    authority = AnkoleWeb.Plugs.RequestHost.origin(conn) |> URI.parse() |> Map.fetch!(:authority)

    %{conn | req_headers: List.keystore(conn.req_headers, "host", 0, {"host", authority})}
    |> put_req_header("connection", "Upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> put_req_header("sec-websocket-version", "13")
  end

  @doc """
  Marks setup completed, creates one root admin, and returns a conn with an
  active Console admin session.
  """
  def active_admin_conn(conn) do
    {conn, _principal_uid} = active_admin_conn_with_principal(conn)
    conn
  end

  @doc """
  The `active_admin_conn/1` flow, returning the admin principal uid with the
  conn.
  """
  def active_admin_conn_with_principal(conn) do
    tenant = conn.assigns[:test_tenant] || elem(Ankole.Tenants.privileged(), 1)
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    Ankole.Repo.with_tenant(tenant.id, fn -> active_admin_conn_in_tenant(conn) end)
  end

  defp active_admin_conn_in_tenant(conn) do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    human =
      PrincipalsFixtures.human_fixture(%{uid: PrincipalsFixtures.unique_uid("console-admin")})

    {:ok, _root} = Ankole.PrincipalsFixtures.first_site_admin_fixture(human.principal.uid)

    session_conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> WebSession.put_admin_session(%{
        principal_uid: human.principal.uid,
        provider_id: "lark-main",
        external_id: "external-1"
      })

    {session_conn, human.principal.uid}
  end

  @doc "Returns a Console API connection with a browser session and CSRF proof."
  def console_conn(conn) do
    {conn, _uid} = console_conn_with_principal(conn)
    conn
  end

  @doc "Returns the Console API connection and its administrator Principal UID."
  def console_conn_with_principal(conn) do
    tenant = conn.assigns[:test_tenant] || elem(Ankole.Tenants.privileged(), 1)

    Ankole.Repo.with_tenant(tenant.id, fn ->
      {conn, uid} = active_admin_conn_with_principal(conn)
      conn = conn |> with_console_csrf() |> get(~p"/.internal-apis/session") |> recycle_api()
      {conn, uid}
    end)
  end

  @doc "Recycles a Console API connection with its cookie, CSRF proof, and JSON content type."
  def recycle_api(conn) do
    conn
    |> recycle()
    |> put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("x-csrf-token", get_req_header(conn, "x-csrf-token") |> List.first())
    |> put_req_header("content-type", "application/json")
  end

  @doc "Adds same-origin and CSRF proof to a browser session."
  def with_console_csrf(conn) do
    if state = WebSession.csrf_state(conn) do
      Plug.CSRFProtection.delete_csrf_token()
      Plug.CSRFProtection.load_state(conn.secret_key_base, state)
    end

    csrf_token = Plug.CSRFProtection.get_csrf_token()
    csrf_state = Plug.CSRFProtection.dump_state()

    origin =
      URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})

    conn
    |> put_session("_csrf_token", csrf_state)
    |> put_req_header("origin", origin)
    |> put_req_header("x-csrf-token", csrf_token)
  end
end
