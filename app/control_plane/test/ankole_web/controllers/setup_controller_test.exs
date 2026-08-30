defmodule AnkoleWeb.SetupControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.IdentityProviders
  alias Ankole.Plugins.Config, as: PluginsConfig
  alias Ankole.Repo
  alias Ankole.Setup.Bootstrap
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

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
      |> post(~p"/.internal-apis/setup/sessions", %{
        "activationCode" => "WRONG000",
        "locale" => "zh-Hans-CN"
      })

    assert json_response(conn, 401)["error"] == "invalid bootstrap activation code"
    assert get_session(conn, :setup_session) == nil
    assert get_session(conn, :setup_oidc_state) == nil

    # The rejected request must not persist its locale.
    refute Repo.get_by(AppConfigure.AppConfig, scope: "global", key: "i18n.default_locale")
  end

  test "setup state reports the forwarded origin the callback URL is built from", %{conn: conn} do
    conn =
      conn
      |> Map.merge(%{host: "ankole.example.com", port: 80})
      |> init_test_session(%{})
      |> put_req_header("x-forwarded-proto", "https")
      |> get(~p"/.internal-apis/setup/state")

    assert json_response(conn, 200)["publicBaseURL"] == "https://ankole.example.com"
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
      |> Map.merge(%{host: "ankole.example.com", port: 80})
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> put_req_header("x-forwarded-proto", "https")
      |> post(~p"/.internal-apis/setup/identity-providers/lark-main/oidc/authorizations")

    %{"authorizationURL" => authorization_url} = json_response(conn, 200)

    redirect_uri =
      authorization_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("redirect_uri")

    assert redirect_uri ==
             "https://ankole.example.com/sessions/oidc/lark-main/callback"

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
      |> post(~p"/.internal-apis/setup/identity-providers/dingtalk-main/oidc/authorizations")

    assert json_response(conn, 400)["error"] =~ "invalidClientIdOrSecret"
    assert WebSession.setup_oidc_state(conn) == nil
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
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_session()
      |> get(~p"/.internal-apis/setup/identity-provider-adapters")

    assert %{"adapters" => adapters} = json_response(conn, 200)

    lark = Enum.find(adapters, &(&1["adapterID"] == "lark"))
    assert lark["displayName"]["default"] == "Lark"
    assert lark["defaultProviderID"] == "lark-main"

    assert hd(lark["fields"])["label"]["zh-Hans-CN"] == "App ID"

    assert hd(lark["fields"])["description"]["default"] ==
             "Find it under Basic information > Credentials in the developer console."

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
      |> get(~p"/.internal-apis/setup/identity-provider-adapters")

    assert %{"adapters" => adapters} = json_response(conn, 200)
    assert Enum.any?(adapters, &(&1["adapterID"] == "lark"))
    assert Enum.any?(adapters, &(&1["adapterID"] == "slack"))
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

  describe "POST /.internal-apis/setup/local-admin" do
    test "creates the administrator, completes setup, and signs the browser in", %{conn: conn} do
      setup_conn =
        conn
        |> init_test_session(%{})
        |> WebSession.put_setup_session()

      put_conn =
        put(setup_conn, ~p"/.internal-apis/setup/identity-providers/local-main", %{
          "adapterID" => "local",
          "config" => %{"retry_protection" => %{"enabled" => true}},
          "enabled" => true
        })

      assert json_response(put_conn, 200)["adapter_id"] == "local"

      conn =
        post(put_conn, ~p"/.internal-apis/setup/local-admin", %{
          "email" => "Admin@Example.com",
          "password" => "hunter2-long"
        })

      assert %{"returnTo" => "/console"} = json_response(conn, 200)
      assert {:ok, true} = SetupConfig.completed?()
      assert get_session(conn, :setup_session) == nil

      conn = get(conn, ~p"/.internal-apis/session")

      assert %{
               "authenticated" => true,
               "principalUID" => "admin@example.com",
               "providerID" => "local-main"
             } = json_response(conn, 200)

      assert Ankole.AdminAuth.active_human_admin?("admin@example.com")

      assert {:ok, %{must_change_password: false}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(
                 "admin@example.com",
                 "hunter2-long"
               )
    end

    test "requires the local provider, a valid email, and a six-character password", %{
      conn: conn
    } do
      setup_conn =
        conn
        |> init_test_session(%{})
        |> WebSession.put_setup_session()

      conn =
        post(setup_conn, ~p"/.internal-apis/setup/local-admin", %{
          "email" => "admin@example.com",
          "password" => "hunter2-long"
        })

      assert json_response(conn, 409)["error"] == "local identity provider is not configured"

      {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)

      conn =
        post(setup_conn, ~p"/.internal-apis/setup/local-admin", %{
          "email" => "not-an-email",
          "password" => "hunter2-long"
        })

      assert json_response(conn, 422)["error"] == "email is invalid"

      conn =
        post(setup_conn, ~p"/.internal-apis/setup/local-admin", %{
          "email" => "admin@example.com",
          "password" => "short"
        })

      assert json_response(conn, 422)["error"] == "password must be at least 6 characters"
    end

    test "cannot run again after setup completes", %{conn: conn} do
      {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)
      {:ok, true} = SetupConfig.put_completed(true)

      conn =
        conn
        |> init_test_session(%{})
        |> WebSession.put_setup_session()
        |> post(~p"/.internal-apis/setup/local-admin", %{
          "email" => "admin@example.com",
          "password" => "hunter2-long"
        })

      assert json_response(conn, 409)["error"] == "setup already completed"
    end
  end
end
