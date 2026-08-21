defmodule AnkoleWeb.AppConfigurationControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Schema
  alias Ankole.AuthZ
  alias Ankole.IdentityProviders.Config, as: IdentityProvidersConfig
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    {:ok, prefix: "__test.console_api.#{System.unique_integer([:positive])}"}
  end

  test "missing bearer token returns 401 before OpenAPI body validation", %{conn: conn} do
    conn =
      put(conn, ~p"/api/v1/app-configurations/anything", %{
        "unexpected" => true
      })

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "OpenAPI JSON includes console REST and SPA auth routes for generated clients", %{
    conn: conn
  } do
    conn = get(conn, ~p"/api/v1/openapi.json")
    paths = json_response(conn, 200)["paths"]

    assert Map.has_key?(paths, "/.internal-apis/oauth/token")
    assert Map.has_key?(paths, "/.internal-apis/session")
    assert Map.has_key?(paths, "/api/v1/app-configurations")
    assert Map.has_key?(paths, "/api/v1/app-configurations/{key}")
    assert Map.has_key?(paths, "/api/v1/app-configurations/{key}/decryptions")
    assert Map.has_key?(paths, "/api/v1/ai-gateway/models")
  end

  test "unversioned public API paths are not registered", %{conn: conn} do
    conn = get(conn, "/api/openapi.json")

    assert response(conn, 404)
  end

  test "bearer-authenticated invalid request bodies return the uniform 422 envelope", %{
    conn: conn
  } do
    conn = bearer_conn(conn)

    conn =
      put(conn, ~p"/api/v1/app-configurations/anything", %{
        "unexpected" => true
      })

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "request validation failed",
               "details" => [_detail | _]
             }
           } = json_response(conn, 422)
  end

  test "admin can list, update, read, and reset exact AppConfigure entries", %{
    conn: conn,
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "exact"),
        encrypted: false,
        schema: Schema.integer(),
        default_value: 1,
        description: "Exact integer setting"
      )

    assert :ok = AppConfigure.register_definitions([definition])

    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"value" => 1, "source" => "default", "editable" => true} =
             entry(entries, definition.key)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/#{definition.key}", %{"value" => 7})

    assert %{
             "app_configuration" => %{
               "key" => key,
               "value" => 7,
               "source" => "global",
               "overridden" => true
             }
           } = json_response(conn, 200)

    assert key == definition.key

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/#{definition.key}", %{})

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/app-configurations/#{definition.key}")

    assert %{"app_configuration" => %{"value" => 7, "source" => "global"}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/app-configurations/#{definition.key}")

    assert %{
             "app_configuration" => %{
               "value" => 1,
               "source" => "default",
               "overridden" => false
             }
           } = json_response(conn, 200)
  end

  test "encrypted values stay hidden until the admin explicitly decrypts", %{
    conn: conn,
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "secret"),
        encrypted: true,
        schema: Schema.object(),
        description: "Secret setting"
      )

    assert :ok = AppConfigure.register_definitions([definition])
    conn = bearer_conn(conn)

    conn =
      put(conn, ~p"/api/v1/app-configurations/#{definition.key}", %{
        "value" => %{"apiKey" => "secret-api-key"}
      })

    assert %{"app_configuration" => encrypted_item} = json_response(conn, 200)
    assert encrypted_item["key"] == definition.key
    assert encrypted_item["encrypted"] == true
    assert encrypted_item["source"] == "global"
    refute Map.has_key?(encrypted_item, "value")

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/app-configurations/#{definition.key}")

    assert %{"app_configuration" => encrypted_detail} = json_response(conn, 200)
    refute Map.has_key?(encrypted_detail, "value")

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/#{definition.key}", %{})

    assert %{"app_configuration" => preserved_item} = json_response(conn, 200)
    assert preserved_item["encrypted"] == true
    assert preserved_item["present"] == true
    refute Map.has_key?(preserved_item, "value")

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/app-configurations/#{definition.key}/decryptions", %{})

    assert %{
             "decrypted_value" => %{
               "key" => key,
               "value" => %{"apiKey" => "secret-api-key"}
             }
           } = json_response(conn, 200)

    assert key == definition.key
  end

  test "pattern policies are listed but only existing concrete pattern rows are editable", %{
    conn: conn,
    prefix: prefix
  } do
    pattern =
      AppConfigure.define_pattern(
        id: key(prefix, "plugin"),
        key_pattern: Regex.compile!("\\A#{Regex.escape(key(prefix, "plugin"))}\\.[a-z]+\\z"),
        encrypted: false,
        schema: Schema.object(),
        description: "Plugin runtime setting"
      )

    runtime_key = pattern.id <> ".alpha"

    assert :ok = AppConfigure.register_patterns([pattern])
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"kind" => "pattern", "editable" => false, "pattern" => pattern_source} =
             entry(entries, pattern.id)

    assert pattern_source == Regex.source(pattern.key_pattern)
    refute Enum.any?(entries, &(&1["key"] == runtime_key))

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/#{runtime_key}", %{"value" => %{"enabled" => true}})

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    assert {:ok, %{"enabled" => true}} =
             AppConfigure.put_global_by_key(runtime_key, %{"enabled" => true})

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/app-configurations")

    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"kind" => "pattern_concrete", "editable" => true, "value" => %{"enabled" => true}} =
             entry(entries, runtime_key)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/#{runtime_key}", %{"value" => %{"enabled" => false}})

    assert %{"app_configuration" => %{"value" => %{"enabled" => false}}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/app-configurations/#{runtime_key}")

    assert %{
             "app_configuration" => %{
               "key" => ^runtime_key,
               "editable" => false,
               "overridden" => false
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/app-configurations")

    assert %{"app_configurations" => entries} = json_response(conn, 200)
    refute Enum.any?(entries, &(&1["key"] == runtime_key))
  end

  test "unknown AppConfigure keys are not writable through the console API", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/app-configurations/not.registered", %{"value" => "value"})

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "setup-owned AppConfigure keys are visible but not writable through the console API", %{
    conn: conn
  } do
    assert {:ok, "ABCDEFGH"} = SetupConfig.put_bootstrap_activation_code("ABCDEFGH")
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"editable" => false, "value" => true} = entry(entries, "setup.completed")

    assert %{"editable" => false, "value" => "ABCDEFGH"} =
             entry(entries, "setup.bootstrap_activation_code")

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/setup.completed", %{"value" => false})

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/app-configurations/setup.bootstrap_activation_code")

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)
    assert {:ok, true} = SetupConfig.completed?()
    assert {:ok, "ABCDEFGH"} = SetupConfig.bootstrap_activation_code()
  end

  test "Installation-owned AppConfigure keys stay readable while their owner keeps writing them",
       %{conn: conn} do
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)
    assert %{"editable" => false} = entry(entries, "runtime_fabric.worker_auth_key")
    assert %{"editable" => false} = entry(entries, "principals.identity_providers.active")

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/principals.identity_providers.active", %{"value" => []})

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/runtime_fabric.worker_auth_key", %{"value" => "leaked"})

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    # Closing the Console path must not close the path the owning API uses.
    assert {:ok, []} = IdentityProvidersConfig.put_active_providers([])
  end

  defp key(prefix, name), do: prefix <> "." <> name

  defp entry(entries, key) do
    Enum.find(entries, &(&1["key"] == key))
  end
end
