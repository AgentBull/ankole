defmodule AnkoleWeb.ControlPlanePluginControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    AppConfigureRegistry.clear_for_test()
    AppConfigureCache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

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
    conn = console_conn(conn)

    response = conn |> get(~p"/api/v1/site/control-plane-plugins") |> json_response(200)
    assert [first | _rest] = response["control_plane_plugins"]

    assert Map.keys(first) |> Enum.sort() ==
             ~w(active configured_enabled description display_name id restart_required)

    desired = not first["active"]

    changed =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/site/control-plane-plugins", %{"id" => first["id"], "enabled" => desired})
      |> json_response(200)
      |> Map.fetch!("control_plane_plugins")
      |> Enum.find(&(&1["id"] == first["id"]))

    assert changed["configured_enabled"] == desired
    assert changed["active"] == first["active"]
    assert changed["restart_required"] == true

    restored =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/site/control-plane-plugins", %{
        "id" => first["id"],
        "enabled" => first["active"]
      })
      |> json_response(200)
      |> Map.fetch!("control_plane_plugins")
      |> Enum.find(&(&1["id"] == first["id"]))

    assert restored["restart_required"] == false
  end

  test "requires authentication and rejects unknown Control Plane Plugins", %{conn: conn} do
    assert conn |> get(~p"/api/v1/site/control-plane-plugins") |> json_response(401)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> console_conn()
             |> put(~p"/api/v1/site/control-plane-plugins", %{
               "id" => "missing",
               "enabled" => false
             })
             |> json_response(404)
  end

  test "an assigned Worker prevents disabling its Plugin through the Console", %{conn: conn} do
    alias Ankole.AgentWorkers.{AgentWorker, Providers}
    alias Ankole.Plugins.VercelWorkerProvider.Provider, as: Vercel

    {:ok, _} = Ankole.Plugins.put_configured_enabled("vercel-worker-provider", true)

    {:ok, provider} =
      Providers.create(%{
        provider_id: "vercel-console",
        kind: "vercel",
        display_name: "Vercel",
        config: Vercel.definition().example,
        credentials: %{"token" => "test"}
      })

    Repo.insert!(%AgentWorker{
      agent_uid: "plugin-console-worker",
      provider_id: provider.provider_id,
      state: :deleting
    })

    response =
      conn
      |> console_conn()
      |> put(~p"/api/v1/site/control-plane-plugins", %{
        id: "vercel-worker-provider",
        enabled: false
      })
      |> json_response(409)

    assert response["error"]["code"] == "worker_provider_plugin_in_use"
    assert response["error"]["message"] =~ provider.provider_id
    assert {:ok, ids} = Ankole.Plugins.enabled_ids()
    assert "vercel-worker-provider" in ids
  end
end
