defmodule AnkoleWeb.ConsolePolicyTest do
  use AnkoleWeb.ConnCase, async: true

  import Ecto.Query

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.Repo
  alias AnkoleWeb.ConsolePolicy

  import Ankole.PrincipalsFixtures

  test "authorizes active admins through AuthZ console grants", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("console-policy-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn = Plug.Conn.assign(conn, :current_principal_uid, human.principal.uid)

    assert :ok = ConsolePolicy.authorize(conn, "ai_gateway_providers", "read")
    assert {:error, :forbidden} = ConsolePolicy.authorize(conn, "ai_gateway_providers", "publish")
  end

  test "does not repair missing console grants on each request", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("console-policy-no-repair")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    Repo.delete_all(
      from grant in Grant,
        where:
          grant.resource_pattern == "**" and grant.action == "read" and grant.condition == "true"
    )

    conn = Plug.Conn.assign(conn, :current_principal_uid, human.principal.uid)

    assert {:error, :forbidden} = ConsolePolicy.authorize(conn, "ai_gateway_providers", "read")
  end
end
