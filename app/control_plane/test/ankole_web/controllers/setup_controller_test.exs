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
          grant.resource_pattern == "**" and grant.action == "read" and grant.condition == "true"
    )

    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    assert {:ok, %{completed: true, activation_code: nil}} = Bootstrap.initialize()

    assert Repo.exists?(
             from grant in Grant,
               where:
                 grant.resource_pattern == "**" and grant.action == "read" and
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

    assert response["enabledPluginIDs"] == ["lark-adapter"]
    assert Enum.any?(response["plugins"], &(&1["id"] == "slack-adapter"))

    updated =
      conn
      |> recycle()
      |> api_put(~p"/api/v2/browser/setup/plugins/enabled", %{
        "pluginIDs" => ["lark-adapter", "slack-adapter"]
      })
      |> api_response(200)

    assert updated["enabledPluginIDs"] == ["lark-adapter", "slack-adapter"]
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

  describe "POST /api/v2/browser/setup/local-admin" do
    test "creates the administrator, completes setup, and signs the browser in", %{
      conn: conn,
      tenant: tenant
    } do
      setup_conn =
        conn
        |> init_test_session(%{})
        |> WebSession.put_setup_session()

      put_conn =
        api_put(setup_conn, ~p"/api/v2/browser/setup/identity-providers/local-main", %{
          "adapterID" => "local",
          "config" => %{"retry_protection" => %{"enabled" => true}},
          "enabled" => true
        })

      assert api_response(put_conn, 200)["adapter_id"] == "local"

      conn =
        api_post(recycle(put_conn), ~p"/api/v2/browser/setup/local-admin", %{
          "email" => "Admin@Example.com",
          "password" => "hunter2-long"
        })

      assert %{"returnTo" => "/site-admin-console"} =
               api_response(conn, 200)

      assert {:ok, true} = SetupConfig.completed?()
      assert get_session(conn, :setup_session) == nil

      conn = api_get(recycle(conn), ~p"/api/v2/browser/session")

      assert %{
               "authenticated" => true,
               "principalUID" => uid,
               "providerID" => "local-main"
             } = api_response(conn, 200)

      assert {:ok, _} = Ecto.UUID.cast(uid)
      assert Ankole.AuthZ.site_admin?(uid)

      assert {:ok, %{must_change_password: false}} =
               Ankole.Repo.with_tenant(tenant.id, fn ->
                 Ankole.IdentityProviders.LocalPassword.authenticate(
                   "admin@example.com",
                   "hunter2-long"
                 )
               end)
    end

    test "requires the local provider, a valid email, and a six-character password", %{
      conn: conn
    } do
      setup_conn =
        conn
        |> init_test_session(%{})
        |> WebSession.put_setup_session()

      conn =
        api_post(setup_conn, ~p"/api/v2/browser/setup/local-admin", %{
          "email" => "admin@example.com",
          "password" => "hunter2-long"
        })

      assert api_error(conn, 409)["code"] ==
               "local identity provider is not configured"

      {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)

      conn =
        api_post(setup_conn, ~p"/api/v2/browser/setup/local-admin", %{
          "email" => "not-an-email",
          "password" => "hunter2-long"
        })

      assert api_error(conn, 422)["code"] == "email is invalid"

      conn =
        api_post(setup_conn, ~p"/api/v2/browser/setup/local-admin", %{
          "email" => "admin@example.com",
          "password" => "short"
        })

      assert api_error(conn, 422)["code"] ==
               "password must be at least 6 characters"
    end

    test "cannot run again after setup completes", %{conn: conn} do
      {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)

      {:ok, true} =
        Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

      conn =
        conn
        |> init_test_session(%{})
        |> WebSession.put_setup_session()
        |> api_post(~p"/api/v2/browser/setup/local-admin", %{
          "email" => "admin@example.com",
          "password" => "hunter2-long"
        })

      assert api_error(conn, 409)["code"] ==
               "setup already completed"
    end
  end
end
