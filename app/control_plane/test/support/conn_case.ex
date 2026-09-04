defmodule AnkoleWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AnkoleWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  @endpoint AnkoleWeb.Endpoint

  use AnkoleWeb, :verified_routes

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ankole.AuthZ
  alias Ankole.PrincipalsFixtures
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  using do
    quote do
      # The default endpoint for testing
      @endpoint AnkoleWeb.Endpoint

      use AnkoleWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AnkoleWeb.ConnCase
      import Ankole.DataCase, only: [allow_cache_database_access: 0]
    end
  end

  setup tags do
    Ankole.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
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
    {:ok, true} = SetupConfig.put_completed(true)

    human =
      PrincipalsFixtures.human_fixture(%{uid: PrincipalsFixtures.unique_uid("console-admin")})

    {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

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

  @doc """
  Returns a fresh conn that carries a Console API bearer token minted through
  the browser-session grant of an active admin session.
  """
  def bearer_conn(conn) do
    {conn, _principal_uid} = bearer_conn_with_principal(conn)
    conn
  end

  @doc """
  The `bearer_conn/1` flow, returning the admin principal uid with the conn.
  """
  def bearer_conn_with_principal(conn) do
    {session_conn, principal_uid} = active_admin_conn_with_principal(conn)

    session_conn
    |> with_console_csrf()
    |> post(~p"/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
    |> then(&{&1, principal_uid})
  end

  @doc """
  Recycles a conn while keeping its bearer authorization and JSON content type.
  """
  def recycle_api(conn) do
    conn
    |> recycle()
    |> put_req_header("authorization", get_req_header(conn, "authorization") |> List.first())
    |> put_req_header("content-type", "application/json")
  end

  @doc "Adds the same-origin and CSRF proof required by the Console token grant."
  def with_console_csrf(conn) do
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
