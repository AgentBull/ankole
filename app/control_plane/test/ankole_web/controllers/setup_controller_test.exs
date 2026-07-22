defmodule AnkoleWeb.SetupControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.Plugins.Config, as: PluginsConfig
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

  test "POST /.internal-apis/setup/bootstrap-activation-code/log-entries reprints the current activation code",
       %{conn: conn} do
    assert {:ok, "ABCDEFGH"} = SetupConfig.put_bootstrap_activation_code("ABCDEFGH")
    original_logger_level = Logger.level()
    Logger.configure(level: :notice)
    on_exit(fn -> Logger.configure(level: original_logger_level) end)

    test_pid = self()

    log =
      capture_log([level: :notice, metadata: [:activation_code]], fn ->
        conn =
          conn
          |> init_test_session(%{})
          |> post(~p"/.internal-apis/setup/bootstrap-activation-code/log-entries", %{})

        send(test_pid, {:response, conn})
      end)

    assert_receive {:response, conn}
    assert json_response(conn, 200) == %{"ok" => true}
    assert log =~ "SETUP ACTIVATION CODE: ABCDEFGH"
    assert {:ok, "ABCDEFGH"} = SetupConfig.bootstrap_activation_code()
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

  test "GET /.internal-apis/setup/identity-provider-adapters uses adapter declaration fields",
       %{conn: conn} do
    :ok = PluginsConfig.ensure_registered()

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> get(~p"/.internal-apis/setup/identity-provider-adapters")

    assert %{"adapters" => adapters} = json_response(conn, 200)

    lark = Enum.find(adapters, &(&1["adapterID"] == "lark"))
    assert lark["displayName"]["default"] == "Lark"
    assert lark["defaultProviderID"] == "lark-main"

    assert Enum.map(lark["fields"], & &1["path"]) == [
             "appID",
             "appSecret",
             "domain",
             "oidc.enabled",
             "oidc.scopes",
             "sync.contacts",
             "sync.websocket",
             "sync.pageSize"
           ]

    assert hd(lark["fields"])["label"]["zh-Hans-CN"] == "应用 ID"
    assert hd(lark["fields"])["description"]["default"] == "Self-built app identifier."

    fields_by_path = Map.new(lark["fields"], &{&1["path"], &1})
    assert fields_by_path["appID"]["advanced"] == false
    assert fields_by_path["oidc.scopes"]["advanced"] == true
    assert fields_by_path["sync.websocket"]["advanced"] == true
    assert fields_by_path["sync.pageSize"]["advanced"] == true
  end

  test "setup reads and writes enabled plugin ids without inverting the selection", %{conn: conn} do
    assert {:ok, ["lark-adapter"]} = PluginsConfig.put_enabled_ids(["lark-adapter"])

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()

    conn = get(conn, ~p"/.internal-apis/setup/plugins")
    response = json_response(conn, 200)

    assert response["enabledPluginIDs"] == ["lark-adapter"]
    assert Enum.any?(response["plugins"], &(&1["id"] == "slack-adapter"))

    updated =
      conn
      |> recycle()
      |> put(~p"/.internal-apis/setup/plugins/enabled", %{
        "pluginIDs" => ["lark-adapter", "slack-adapter"]
      })
      |> json_response(200)

    assert updated["enabledPluginIDs"] == ["lark-adapter", "slack-adapter"]
    assert {:ok, ["lark-adapter", "slack-adapter"]} = PluginsConfig.enabled_ids()
  end

  test "setup rejects unknown enabled plugin ids", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> put(~p"/.internal-apis/setup/plugins/enabled", %{"pluginIDs" => ["missing-plugin"]})

    assert json_response(conn, 400)["error"] =~ "unknown_plugin_ids"
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
