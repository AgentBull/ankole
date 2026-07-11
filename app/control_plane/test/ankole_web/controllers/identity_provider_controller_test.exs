defmodule AnkoleWeb.IdentityProviderControllerTest do
  use AnkoleWeb.ConnCase, async: false
  use Oban.Testing, repo: Ankole.Repo

  import Ecto.Query, only: [from: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Plugins.Config, as: PluginsConfig
  alias Ankole.Plugins.LarkAdapter
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = PluginsConfig.ensure_registered()
    :ok = IdentityProviderConfig.ensure_registered()
    :ok = SetupConfig.ensure_registered()
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())
    {:ok, true} = SetupConfig.put_completed(true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "missing bearer token returns 401 before request body validation", %{conn: conn} do
    conn =
      put(conn, ~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "config" => "not an object"
      })

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "bearer-authenticated callers without resource grants are forbidden", %{conn: conn} do
    conn = bearer_conn(conn)
    revoke_console_grants()

    conn = get(conn, ~p"/api/v1/identity-provider-adapters")

    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
  end

  test "admin manages identity providers and enqueues manual full sync", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/identity-provider-adapters")

    assert %{"identity_provider_adapters" => adapters} = json_response(conn, 200)
    assert Enum.map(adapters, & &1["adapter_id"]) == ["lark", "slack"]

    adapter = Enum.find(adapters, &(&1["adapter_id"] == "lark"))
    assert adapter["adapter_id"] == "lark"
    assert adapter["display_name"]["default"] == "Lark"
    assert "directory_full_sync" in adapter["capabilities"]

    assert Enum.map(adapter["fields"], & &1["path"]) == [
             "appID",
             "appSecret",
             "domain",
             "oidc.enabled",
             "oidc.scopes",
             "sync.contacts",
             "sync.websocket",
             "sync.pageSize"
           ]

    assert Enum.find(adapter["fields"], &(&1["path"] == "appSecret"))["encrypted"] == true
    assert Enum.find(adapter["fields"], &(&1["path"] == "sync.websocket"))["advanced"] == true

    slack = Enum.find(adapters, &(&1["adapter_id"] == "slack"))
    assert slack["default_provider_id"] == "slack-main"
    assert slack["display_name"]["default"] == "Slack"
    assert "directory_realtime_sync" in slack["capabilities"]

    assert Enum.map(slack["fields"], & &1["path"]) == [
             "clientID",
             "clientSecret",
             "teamID",
             "botToken",
             "appToken",
             "oidc.enabled",
             "oidc.scopes",
             "sync.contacts",
             "sync.websocket",
             "sync.pageSize"
           ]

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "enabled" => true,
        "config" => %{
          "appID" => "cli_identity_console",
          "appSecret" => "secret-console",
          "sync" => %{"contacts" => true, "websocket" => true}
        }
      })

    assert %{
             "identity_provider" => %{
               "provider_id" => "lark-main",
               "adapter_id" => "lark",
               "config_key" => "principals.identity_providers.lark.lark-main",
               "enabled" => true,
               "config" => %{"appID" => "cli_identity_console", "appSecret" => "********"}
             }
           } = json_response(conn, 200)

    assert_enqueued(
      worker: SyncProvider,
      args: %{"provider_id" => "lark-main", "reason" => "provider_saved", "source" => "console"}
    )

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/identity-providers")

    assert %{
             "identity_providers" => [
               %{"provider_id" => "lark-main", "config" => listed_config}
             ]
           } =
             json_response(conn, 200)

    assert listed_config["appSecret"] == "********"

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/identity-providers/lark-main/sync-runs", %{})

    assert %{
             "sync_run" => %{
               "provider_id" => "lark-main",
               "status" => "enqueued"
             }
           } = json_response(conn, 200)

    assert_enqueued(
      worker: SyncProvider,
      args: %{"provider_id" => "lark-main", "reason" => "manual", "source" => "console"}
    )
  end

  test "saving an existing provider preserves masked secret fields", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "enabled" => true,
        "config" => %{
          "appID" => "cli_identity_console",
          "appSecret" => "secret-console"
        }
      })

    assert %{"identity_provider" => %{"config" => %{"appSecret" => "********"}}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "enabled" => true,
        "config" => %{
          "appID" => "cli_identity_console_renamed",
          "appSecret" => "********",
          "sync" => %{"contacts" => true}
        }
      })

    assert %{"identity_provider" => %{"config" => %{"appSecret" => "********"}}} =
             json_response(conn, 200)

    assert {:ok, config} = AppConfigure.get_by_key(LarkConfig.identity_config_key("lark-main"))
    assert config["appID"] == "cli_identity_console_renamed"
    assert config["appSecret"] == "secret-console"
  end

  test "manual full sync returns a clear error when directory sync is disabled", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "enabled" => true,
        "config" => %{
          "appID" => "cli_identity_console",
          "appSecret" => "secret-console",
          "sync" => %{"contacts" => false}
        }
      })

    assert %{"identity_provider" => %{"enabled" => true}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/identity-providers/lark-main/sync-runs", %{})

    assert %{
             "error" => %{
               "code" => "sync_disabled",
               "message" => "directory sync is disabled for this identity provider"
             }
           } = json_response(conn, 422)
  end

  test "write and manual sync error paths return explicit envelopes", %{conn: conn} do
    conn = bearer_conn(conn)

    conn =
      put(conn, ~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "missing",
        "enabled" => true,
        "config" => %{}
      })

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "enabled" => true,
        "config" => "not an object"
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/identity-providers/missing-main/sync-runs", %{})

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "OpenAPI JSON includes identity provider console endpoints", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/openapi.json")
    paths = json_response(conn, 200)["paths"]

    assert Map.has_key?(paths, "/api/v1/identity-provider-adapters")
    assert Map.has_key?(paths, "/api/v1/identity-providers")
    assert Map.has_key?(paths, "/api/v1/identity-providers/{provider_id}")
    assert Map.has_key?(paths, "/api/v1/identity-providers/{provider_id}/sync-runs")
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
    human = human_fixture(%{uid: unique_uid("identity-provider-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp revoke_console_grants do
    Repo.delete_all(from grant in Grant, where: grant.resource_pattern == "**")
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
