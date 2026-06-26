defmodule AnkoleWeb.ConsolePolicyTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AuthZ
  alias AnkoleWeb.ConsolePolicy

  import Ankole.PrincipalsFixtures

  test "authorizes active admins through AuthZ console grants", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("console-policy-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn = Plug.Conn.assign(conn, :current_principal_uid, human.principal.uid)

    assert :ok = ConsolePolicy.authorize(conn, "llm_providers", "read")
    assert {:error, :forbidden} = ConsolePolicy.authorize(conn, "llm_providers", "publish")
  end
end
