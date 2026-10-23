defmodule AnkoleWeb.PrincipalControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  describe "local password resets" do
    test "a reset requires an enabled local provider", %{conn: conn} do
      conn = console_conn(conn)
      %{principal: human} = human_fixture()

      reset_conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/#{human.uid}/local-password-resets", %{})

      assert %{"error" => %{"code" => "local_identity_provider_disabled"}} =
               json_response(reset_conn, 409)
    end

    test "resets a local password for a human with an email", %{conn: conn} do
      conn = console_conn(conn)
      enable_local_provider()
      %{principal: human, human_user: human_user} = human_fixture()

      conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/#{human.uid}/local-password-resets", %{
          "must_change_password" => false
        })

      assert %{"initial_password" => initial_password} = json_response(conn, 200)

      assert {:ok, %{must_change_password: false}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(
                 human_user.email,
                 initial_password
               )

      %{principal: agent} = agent_fixture()

      agent_conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/#{agent.uid}/local-password-resets", %{})

      assert %{"error" => %{"code" => "not_human"}} = json_response(agent_conn, 422)
    end

    test "resetting a password for an unknown principal returns 404", %{conn: conn} do
      conn = console_conn(conn)
      enable_local_provider()

      conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/no-such-user/local-password-resets", %{})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  defp enable_local_provider do
    {:ok, _provider} =
      Ankole.IdentityProviders.save_provider("local-main", "local", %{}, true)

    :ok
  end
end
