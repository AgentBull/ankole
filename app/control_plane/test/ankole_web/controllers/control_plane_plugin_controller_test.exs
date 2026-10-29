defmodule AnkoleWeb.ControlPlanePluginControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  defmodule MetadataFreePlugin do
    @behaviour Ankole.Plugins.Plugin
    @impl true
    def plugin_id, do: "fixture-metadata-free"
    @impl true
    def activation, do: :always
  end

  setup do
    AppConfigureRegistry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
    end)

    :ok
  end

  test "writes next-start configuration without pretending the current process changed", %{
    conn: conn
  } do
    conn = console_conn(conn)

    response = conn |> api(:get, ~p"/api/v2/site/control-plane-plugins") |> json_response(200)
    assert first = Enum.find(response["control_plane_plugins"], &(&1["activation"] == "optional"))

    assert Map.keys(first) |> Enum.sort() ==
             ~w(activation active configured_enabled description display_name id restart_required)

    desired = not first["active"]

    changed =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/site/control-plane-plugins", %{
        "id" => first["id"],
        "enabled" => desired
      })
      |> json_response(200)
      |> Map.fetch!("control_plane_plugins")
      |> Enum.find(&(&1["id"] == first["id"]))

    assert changed["configured_enabled"] == desired
    assert changed["active"] == first["active"]
    assert changed["restart_required"] == true

    restored =
      conn
      |> recycle_api()
      |> api(:put, ~p"/api/v2/site/control-plane-plugins", %{
        "id" => first["id"],
        "enabled" => first["active"]
      })
      |> json_response(200)
      |> Map.fetch!("control_plane_plugins")
      |> Enum.find(&(&1["id"] == first["id"]))

    assert restored["restart_required"] == false
  end

  test "requires authentication and rejects unknown Control Plane Plugins", %{conn: conn} do
    assert conn |> api(:get, ~p"/api/v2/site/control-plane-plugins") |> json_response(401)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> console_conn()
             |> api(:put, ~p"/api/v2/site/control-plane-plugins", %{
               "id" => "missing",
               "enabled" => false
             })
             |> json_response(404)
  end

  test "Ash JSON:API rejects invalid configuration arguments before the operation", %{conn: conn} do
    assert %{
             "errors" => [
               %{"code" => "invalid_body", "source" => %{"pointer" => "/data/enabled"}}
             ]
           } =
             conn
             |> console_conn()
             |> api(:put, ~p"/api/v2/site/control-plane-plugins", %{
               id: "missing",
               enabled: %{}
             })
             |> json_response(400)
  end

  test "the Console lists a fixed Plugin without optional metadata and rejects its deactivation",
       %{conn: conn} do
    snapshot = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Ankole.Plugins.Spec.from_module(MetadataFreePlugin)

    Ankole.Plugins.Registry.update_for_test(fn state ->
      %{
        state
        | discovered: Map.put(state.discovered, spec.id, spec),
          active: Map.put(state.active, spec.id, spec)
      }
    end)

    on_exit(fn -> Ankole.Plugins.Registry.update_for_test(fn _ -> snapshot end) end)

    conn = console_conn(conn)

    plugin =
      conn
      |> api(:get, ~p"/api/v2/site/control-plane-plugins")
      |> json_response(200)
      |> Map.fetch!("control_plane_plugins")
      |> Enum.find(&(&1["id"] == spec.id))

    assert plugin["activation"] == "always"
    assert plugin["configured_enabled"]
    assert plugin["display_name"] == %{"default" => spec.id}
    assert Map.has_key?(plugin, "description")
    assert plugin["description"] == nil

    type = Ankole.ControlPlanePlugins.ConsoleTypes.ControlPlanePluginItem
    assert {:ok, constraints} = Ash.Type.init(type, [])
    assert {:ok, _typed_plugin} = Ash.Type.cast_input(type, plugin, constraints)

    assert %{"errors" => [%{"code" => "control_plane_plugin_always_enabled"}]} =
             conn
             |> api(:put, ~p"/api/v2/site/control-plane-plugins", %{
               id: spec.id,
               enabled: false
             })
             |> json_response(422)
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
      |> api(:put, ~p"/api/v2/site/control-plane-plugins", %{
        id: "vercel-worker-provider",
        enabled: false
      })
      |> json_response(409)

    assert [%{"detail" => detail}] = response["errors"]
    assert detail =~ provider.provider_id
    assert {:ok, ids} = Ankole.Plugins.enabled_ids()
    assert "vercel-worker-provider" in ids
  end

  defp api(conn, method, path, data \\ nil) do
    conn =
      if get_req_header(conn, "x-csrf-token") == [], do: recycle(conn), else: recycle_api(conn)

    conn =
      conn
      |> delete_req_header("content-type")
      |> put_req_header("accept", "application/vnd.api+json")

    conn =
      if data, do: put_req_header(conn, "content-type", "application/vnd.api+json"), else: conn

    dispatch(conn, @endpoint, method, path, data && Jason.encode!(%{data: data}))
  end
end
