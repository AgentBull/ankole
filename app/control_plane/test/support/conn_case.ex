defmodule AnkoleWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  @endpoint AnkoleWeb.Endpoint

  use AnkoleWeb, :verified_routes

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ankole.PrincipalsFixtures
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  using do
    quote do
      @endpoint AnkoleWeb.Endpoint

      use AnkoleWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import AnkoleWeb.ConnCase
      import Ankole.DataCase, only: [allow_cache_database_access: 0]
    end
  end

  setup tags do
    Ankole.DataCase.setup_sandbox(tags)
    tenant = Ankole.DataCase.create_tenant()
    # Fixtures use this tenant; Endpoint.ResetTenant resets it for each request.
    Ankole.Repo.put_tenant_id(tenant.id)
    {:ok, tenant: tenant, conn: Phoenix.ConnTest.build_conn() |> assign(:test_tenant, tenant)}
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
    {:ok, true} = SetupConfig.put_completed(true)

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
