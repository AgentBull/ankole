defmodule AnkoleWeb.ControlPlanePluginControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.AuthZ
  alias Ankole.Plugins.Config, as: PluginConfig
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()
    :ok = SetupConfig.ensure_registered()
    :ok = PluginConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
      AppConfigureCache.clear_for_test()
    end)

    :ok
  end

  test "writes next-start configuration without pretending the current process changed", %{
    conn: conn
  } do
    conn = bearer_conn(conn)

    response = conn |> get(~p"/api/v1/control-plane-plugins") |> json_response(200)
    assert [first | _rest] = response["control_plane_plugins"]

    assert Map.keys(first) |> Enum.sort() ==
             ~w(active configured_enabled description display_name id restart_required)

    desired = not first["active"]

    changed =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/control-plane-plugins", %{"id" => first["id"], "enabled" => desired})
      |> json_response(200)
      |> Map.fetch!("control_plane_plugins")
      |> Enum.find(&(&1["id"] == first["id"]))

    assert changed["configured_enabled"] == desired
    assert changed["active"] == first["active"]
    assert changed["restart_required"] == true

    restored =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/control-plane-plugins", %{
        "id" => first["id"],
        "enabled" => first["active"]
      })
      |> json_response(200)
      |> Map.fetch!("control_plane_plugins")
      |> Enum.find(&(&1["id"] == first["id"]))

    assert restored["restart_required"] == false
  end

  test "requires authentication and rejects unknown Control Plane Plugins", %{conn: conn} do
    assert conn |> get(~p"/api/v1/control-plane-plugins") |> json_response(401)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> bearer_conn()
             |> put(~p"/api/v1/control-plane-plugins", %{"id" => "missing", "enabled" => false})
             |> json_response(404)
  end

  defp bearer_conn(conn) do
    conn
    |> active_admin_conn()
    |> post(~p"/.internal-apis/oauth/token", %{
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
  end

  defp recycle_api(conn) do
    conn
    |> recycle()
    |> put_req_header("authorization", get_req_header(conn, "authorization") |> List.first())
    |> put_req_header("content-type", "application/json")
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("control-plane-plugin-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end
end
