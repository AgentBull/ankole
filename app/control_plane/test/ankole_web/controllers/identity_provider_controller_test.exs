defmodule AnkoleWeb.IdentityProviderControllerTest do
  use AnkoleWeb.ConnCase, async: false
  use Oban.Testing, repo: Ankole.Repo

  import Ecto.Query, only: [from: 2]

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ.Grant
  alias Ankole.IdentityProviders.Jobs.SyncProvider
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

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

    google = Enum.find(adapters, &(&1["adapter_id"] == "google-workspace"))
    assert google["default_provider_id"] == "google-workspace-main"
    refute "directory_realtime_sync" in google["capabilities"]

    adapter = Enum.find(adapters, &(&1["adapter_id"] == "lark"))
    assert adapter["adapter_id"] == "lark"
    assert adapter["display_name"]["default"] == "Lark"
    assert "directory_full_sync" in adapter["capabilities"]

    assert Enum.find(adapter["fields"], &(&1["path"] == "appSecret"))["encrypted"] == true
    assert Enum.find(adapter["fields"], &(&1["path"] == "sync.websocket"))["advanced"] == true

    slack = Enum.find(adapters, &(&1["adapter_id"] == "slack"))
    assert slack["default_provider_id"] == "slack-main"
    assert slack["display_name"]["default"] == "Slack"
    assert "directory_realtime_sync" in slack["capabilities"]

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
               "config" => %{"appID" => "cli_identity_console"},
               "stored_secret_paths" => ["appSecret"]
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "secret-console"

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
               %{
                 "provider_id" => "lark-main",
                 "config" => listed_config,
                 "stored_secret_paths" => ["appSecret"]
               }
             ]
           } =
             json_response(conn, 200)

    refute Map.has_key?(listed_config, "appSecret")
    refute conn.resp_body =~ "secret-console"

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

  test "saving an existing provider preserves blank secret fields", %{conn: conn} do
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

    assert %{
             "identity_provider" => %{
               "config" => %{"appID" => "cli_identity_console"},
               "stored_secret_paths" => ["appSecret"]
             }
           } =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "enabled" => true,
        "config" => %{
          "appID" => "cli_identity_console_renamed",
          "appSecret" => "",
          "sync" => %{"contacts" => true}
        }
      })

    assert %{
             "identity_provider" => %{
               "config" => %{"appID" => "cli_identity_console_renamed"},
               "stored_secret_paths" => ["appSecret"]
             }
           } =
             json_response(conn, 200)

    refute conn.resp_body =~ "secret-console"

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

  test "a missing required adapter config field names the field in the error", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/identity-providers/lark-main", %{
        "adapter_id" => "lark",
        "enabled" => true,
        "config" => %{"appSecret" => "secret-console"}
      })

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "appID is required",
               "details" => [%{"path" => "appID", "kind" => "missing"}]
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

  defp revoke_console_grants do
    Repo.delete_all(from grant in Grant, where: grant.resource_pattern == "**")
  end
end
