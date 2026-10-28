defmodule AnkoleWeb.SetupControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI

  import Ecto.Query
  import ExUnit.CaptureLog
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ.Grant
  alias Ankole.IdentityProviders
  alias Ankole.Plugins.Config, as: PluginsConfig
  alias Ankole.Repo
  alias Ankole.Setup.Bootstrap
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  defmodule FixedPlugin do
    @behaviour Ankole.Plugins.Plugin
    @impl true
    def plugin_id, do: "fixture-fixed-setup"
    @impl true
    def activation, do: :always
  end

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = Ankole.Tenants.ensure_scaffold(tenant)

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "POST /api/v2/browser/setup/bootstrap-activation-code/log-entries reprints the current activation code",
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
          |> api_post(~p"/api/v2/browser/setup/bootstrap-activation-code/log-entries", %{})

        send(test_pid, {:response, conn})
      end)

    assert_receive {:response, conn}
    assert api_response(conn, 200) == %{"ok" => true}
    assert log =~ "SETUP ACTIVATION CODE: ABCDEFGH"
    assert {:ok, "ABCDEFGH"} = SetupConfig.bootstrap_activation_code()
  end

  test "POST /api/v2/browser/setup/sessions clears old setup session and OIDC state on invalid activation code",
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
      |> api_post(~p"/api/v2/browser/setup/sessions", %{
        "activation_code" => "WRONG000",
        "locale" => "zh-Hans-CN"
      })

    assert api_error(conn, 401)["code"] ==
             "invalid bootstrap activation code"

    assert get_session(conn, :setup_session) == nil
    assert get_session(conn, :setup_oidc_state) == nil

    # The rejected request must not persist its locale.
    refute Repo.get_by(AppConfigure.SiteConfig, scope: "global", key: "i18n.default_locale")
  end

  test "setup state reports the forwarded origin the callback URL is built from", %{conn: conn} do
    conn =
      conn
      |> forwarded_https_conn()
      |> init_test_session(%{})
      |> api_get(~p"/api/v2/browser/setup/state")

    assert api_response(conn, 200)["publicBaseURL"] ==
             "https://#{conn.host}"
  end

  test "setup company and business step updates the privileged tenant and stores packs", %{
    conn: conn,
    tenant: tenant
  } do
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_get(~p"/api/v2/browser/setup/brain-packs")

    response = api_response(conn, 200)
    assert response["displayName"] == tenant.display_name
    assert response["slug"] == tenant.slug

    conn =
      conn
      |> recycle()
      |> api_put(~p"/api/v2/browser/setup/brain-packs", %{
        "displayName" => "Acme",
        "slug" => "qa-company",
        "packs" => ["legal"]
      })

    assert api_response(conn, 200) == %{
             "displayName" => "Acme",
             "slug" => "qa-company",
             "packs" => ["legal"]
           }

    assert {:ok, updated} = Ankole.Tenants.get(tenant.id)
    assert updated.display_name == "Acme"
    assert updated.slug == "qa-company"
    assert WebSession.setup_brain_packs(conn) == ["legal"]
  end

  test "setup rejects an invalid tenant slug without changing the profile", %{
    conn: conn,
    tenant: tenant
  } do
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_put(~p"/api/v2/browser/setup/brain-packs", %{
        "displayName" => "Acme",
        "slug" => "not valid",
        "packs" => ["legal"]
      })

    assert api_error(conn, 422)
    assert {:ok, unchanged} = Ankole.Tenants.get(tenant.id)
    assert unchanged.display_name == tenant.display_name
    assert unchanged.slug == tenant.slug
    assert WebSession.setup_brain_packs(conn) == []
  end

  test "OIDC authorization uses the forwarded HTTPS origin for its callback", %{conn: conn} do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "lark-main",
               "lark",
               %{"appID" => "cli_identity", "appSecret" => "secret"},
               true
             )

    conn =
      conn
      |> forwarded_https_conn()
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_post(~p"/api/v2/browser/setup/identity-providers/lark-main/oidc/authorizations")

    %{"authorizationURL" => authorization_url} =
      api_response(conn, 200)

    redirect_uri =
      authorization_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("redirect_uri")

    assert redirect_uri ==
             "https://#{conn.host}/sessions/oidc/lark-main/callback"

    assert WebSession.setup_oidc_state(conn)["redirect_uri"] == redirect_uri
  end

  test "OIDC authorization stops at the provider's own credential rejection", %{conn: conn} do
    assert {:ok, _provider} =
             IdentityProviders.save_provider(
               "dingtalk-main",
               "dingtalk",
               %{
                 "clientId" => "ding_setup_check",
                 "clientSecret" => "wrong-secret",
                 "sync" => %{"contacts" => false}
               },
               true
             )

    previous_options = Req.default_options()
    on_exit(fn -> Req.default_options(previous_options) end)

    Req.default_options(
      plug: fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "code" => "invalidClientIdOrSecret",
          "message" => "无效的clientId或者clientSecret"
        })
      end
    )

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_post(~p"/api/v2/browser/setup/identity-providers/dingtalk-main/oidc/authorizations")

    assert api_error(conn, 400)["code"] =~
             "invalidClientIdOrSecret"

    assert WebSession.setup_oidc_state(conn) == nil
  end

  test "bootstrap repairs console admin grants once when setup is complete" do
    human = human_fixture(%{uid: unique_uid("setup-bootstrap-admin")})
    assert {:ok, _root} = Ankole.PrincipalsFixtures.first_site_admin_fixture(human.principal.uid)

    Repo.delete_all(
      from grant in Grant,
        where:
          grant.resource_pattern == "site_console:**" and grant.action == "read" and
            grant.condition == "true"
    )

    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    assert {:ok, %{completed: true, activation_code: nil}} = Bootstrap.initialize()

    assert Repo.exists?(
             from grant in Grant,
               where:
                 grant.resource_pattern == "site_console:**" and grant.action == "read" and
                   grant.condition == "true"
           )
  end

  test "GET /api/v2/browser/setup/identity-provider-adapters uses adapter declaration fields",
       %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_get(~p"/api/v2/browser/setup/identity-provider-adapters")

    assert %{"adapters" => adapters} = api_response(conn, 200)

    lark = Enum.find(adapters, &(&1["adapterID"] == "lark"))
    assert lark["displayName"]["default"] == "Lark"
    assert lark["defaultProviderID"] == "lark-main"

    fields_by_path = Map.new(lark["fields"], &{&1["path"], &1})
    assert fields_by_path["appID"]["advanced"] == false
    assert fields_by_path["oidc.scopes"]["advanced"] == true
    assert fields_by_path["sync.websocket"]["advanced"] == true
    assert fields_by_path["sync.pageSize"]["advanced"] == true
  end

  test "setup catalog includes boot-loaded adapters outside the current selection", %{conn: conn} do
    assert {:ok, ["lark-adapter"]} = PluginsConfig.put_enabled_ids(["lark-adapter"])

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_get(~p"/api/v2/browser/setup/identity-provider-adapters")

    assert %{"adapters" => adapters} = api_response(conn, 200)
    assert Enum.any?(adapters, &(&1["adapterID"] == "lark"))
    assert Enum.any?(adapters, &(&1["adapterID"] == "slack"))
  end

  test "setup reads and writes enabled plugin ids without inverting the selection", %{conn: conn} do
    assert {:ok, ["lark-adapter"]} = PluginsConfig.put_enabled_ids(["lark-adapter"])

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()

    conn = api_get(conn, ~p"/api/v2/browser/setup/plugins")
    response = api_response(conn, 200)

    assert response["enabledPluginIDs"] == Enum.sort(["lark-adapter" | fixed_plugin_ids()])
    assert Enum.any?(response["plugins"], &(&1["id"] == "slack-adapter"))

    updated =
      conn
      |> recycle()
      |> api_put(~p"/api/v2/browser/setup/plugins/enabled", %{
        "pluginIDs" => ["lark-adapter", "slack-adapter"]
      })
      |> api_response(200)

    assert updated["enabledPluginIDs"] ==
             Enum.sort(["lark-adapter", "slack-adapter" | fixed_plugin_ids()])

    assert {:ok, ["lark-adapter", "slack-adapter"]} = PluginsConfig.enabled_ids()
  end

  test "setup rejects unknown enabled plugin ids", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> api_put(~p"/api/v2/browser/setup/plugins/enabled", %{"pluginIDs" => ["missing-plugin"]})

    assert api_error(conn, 400)["code"] =~ "unknown_plugin_ids"
  end

  test "setup keeps fixed build Plugins selected without adding them to the optional policy", %{
    conn: conn
  } do
    snapshot = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Ankole.Plugins.Spec.from_module(FixedPlugin)

    Ankole.Plugins.Registry.update_for_test(fn state ->
      %{
        state
        | discovered: Map.put(state.discovered, spec.id, spec),
          active: Map.put(state.active, spec.id, spec)
      }
    end)

    on_exit(fn -> Ankole.Plugins.Registry.update_for_test(fn _ -> snapshot end) end)
    assert {:ok, []} = PluginsConfig.put_enabled_ids([])
    fixed_ids = fixed_plugin_ids()

    conn = conn |> init_test_session(%{}) |> WebSession.put_setup_session()
    conn = api_get(conn, ~p"/api/v2/browser/setup/plugins")
    response = api_response(conn, 200)
    assert response["enabledPluginIDs"] == fixed_ids
    assert spec.id in response["enabledPluginIDs"]
    assert %{"activation" => "always"} = Enum.find(response["plugins"], &(&1["id"] == spec.id))

    for selected <- [[], [spec.id]] do
      response =
        conn
        |> recycle()
        |> api_put(~p"/api/v2/browser/setup/plugins/enabled", %{"pluginIDs" => selected})
        |> api_response(200)

      assert response["enabledPluginIDs"] == fixed_ids
      assert {:ok, []} = PluginsConfig.enabled_ids()
    end
  end

  defp fixed_plugin_ids do
    for plugin <- Ankole.Plugins.list_discovered(), plugin.activation == :always, do: plugin.id
  end
end
