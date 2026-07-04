defmodule AnkoleWeb.SetupControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.Repo
  alias Ankole.Setup.Bootstrap
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "POST /.internal-apis/setup/sessions clears old setup session and OIDC state on invalid activation code",
       %{conn: conn} do
    assert {:ok, "ABCDEFGH"} = SetupConfig.put_bootstrap_activation_code("ABCDEFGH")

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> WebSession.put_setup_oidc_state(%{
        provider_id: "lark-main",
        state: "old-state",
        redirect_uri: "http://localhost/sessions/oidc/lark-main/callback"
      })
      |> post(~p"/.internal-apis/setup/sessions", %{"activationCode" => "WRONG000"})

    assert json_response(conn, 401)["error"] == "invalid bootstrap activation code"
    assert get_session(conn, :setup_session) == nil
    assert get_session(conn, :setup_oidc_state) == nil
  end

  test "bootstrap repairs console admin grants once when setup is complete" do
    human = human_fixture(%{uid: unique_uid("setup-bootstrap-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    Repo.delete_all(
      from grant in Grant,
        where:
          grant.resource_pattern == "**" and grant.action == "read" and grant.condition == "true"
    )

    {:ok, true} = SetupConfig.put_completed(true)

    assert {:ok, %{completed: true, activation_code: nil}} = Bootstrap.initialize()

    assert Repo.exists?(
             from grant in Grant,
               where:
                 grant.resource_pattern == "**" and grant.action == "read" and
                   grant.condition == "true"
           )
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
