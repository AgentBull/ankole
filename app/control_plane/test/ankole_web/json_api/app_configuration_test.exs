defmodule AnkoleWeb.JSONAPI.AppConfigurationTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Schema
  alias Ankole.IdentityProviders
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    {:ok, prefix: "__test.console_api.#{System.unique_integer([:positive])}"}
  end

  test "missing browser session returns 401 before OpenAPI body validation", %{conn: conn} do
    conn =
      api_put(conn, ~p"/api/v2/site/app-configurations/anything", %{
        "unexpected" => true
      })

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "site settings have typed generated routes", %{conn: conn} do
    paths =
      conn
      |> console_conn()
      |> api_get("/api/v2/site/openapi.json")
      |> json_response(200)
      |> Map.fetch!("paths")

    assert Map.has_key?(paths, "/api/v2/site/app-configurations")
    assert Map.has_key?(paths, "/api/v2/site/app-configurations/{key}")
    assert Map.has_key?(paths, "/api/v2/site/app-configurations/{key}/decryptions")
  end

  test "unversioned public API paths are not registered", %{conn: conn} do
    conn = api_get(conn, "/api/openapi.json")

    assert response(conn, 404)
  end

  test "invalid setting bodies give field feedback before a write", %{
    conn: conn
  } do
    conn = console_conn(conn)

    conn =
      api_put(conn, ~p"/api/v2/site/app-configurations/anything", %{
        "unexpected" => true
      })

    assert %{"errors" => [%{"detail" => detail} | _]} = json_response(conn, 400)
    assert detail =~ "data"
  end

  test "admin can list, update, read, and reset exact AppConfigure entries", %{
    conn: conn,
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "exact"),
        encrypted: false,
        schema:
          Ankole.AppConfigure.Schema.new(fn
            value when is_integer(value) -> {:ok, value}
            _value -> {:error, :not_integer}
          end),
        default_value: 1,
        description: "Exact integer setting"
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    conn = console_conn(conn)

    conn = api_get(conn, ~p"/api/v2/site/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"value" => 1, "source" => "default", "editable" => true} =
             entry(entries, definition.key)

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/site/app-configurations/#{definition.key}", %{"value" => 7})

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
      |> api_put(~p"/api/v2/site/app-configurations/#{definition.key}", %{})

    assert %{"errors" => [%{"code" => "missing_value"}]} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> api_get(~p"/api/v2/site/app-configurations/#{definition.key}")

    assert %{"app_configuration" => %{"value" => 7, "source" => "global"}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> api_delete(~p"/api/v2/site/app-configurations/#{definition.key}")

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

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])
    conn = console_conn(conn)

    conn =
      api_put(conn, ~p"/api/v2/site/app-configurations/#{definition.key}", %{
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
      |> api_get(~p"/api/v2/site/app-configurations/#{definition.key}")

    assert %{"app_configuration" => encrypted_detail} = json_response(conn, 200)
    refute Map.has_key?(encrypted_detail, "value")

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/site/app-configurations/#{definition.key}", %{})

    assert %{"app_configuration" => preserved_item} = json_response(conn, 200)
    assert preserved_item["encrypted"] == true
    assert preserved_item["present"] == true
    refute Map.has_key?(preserved_item, "value")

    conn =
      conn
      |> recycle_api()
      |> api_post(~p"/api/v2/site/app-configurations/#{definition.key}/decryptions", %{})

    assert %{
             "decrypted_value" => %{
               "key" => key,
               "value" => %{"apiKey" => "secret-api-key"}
             }
           } = json_response(conn, 201)

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

    assert :ok = Ankole.AppConfigure.Registry.register_patterns([pattern])
    conn = console_conn(conn)

    conn = api_get(conn, ~p"/api/v2/site/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"kind" => "pattern", "editable" => false, "pattern" => pattern_source} =
             entry(entries, pattern.id)

    assert pattern_source == Regex.source(pattern.key_pattern)
    refute Enum.any?(entries, &(&1["key"] == runtime_key))

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/site/app-configurations/#{runtime_key}", %{
        "value" => %{"enabled" => true}
      })

    assert %{"errors" => [%{"code" => "pattern_key_not_editable"}]} = json_response(conn, 422)

    assert {:ok, %{"enabled" => true}} =
             AppConfigure.put_global_by_key(runtime_key, %{"enabled" => true})

    conn =
      conn
      |> recycle_api()
      |> api_get(~p"/api/v2/site/app-configurations")

    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"kind" => "pattern_concrete", "editable" => true, "value" => %{"enabled" => true}} =
             entry(entries, runtime_key)

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/site/app-configurations/#{runtime_key}", %{
        "value" => %{"enabled" => false}
      })

    assert %{"app_configuration" => %{"value" => %{"enabled" => false}}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> api_delete(~p"/api/v2/site/app-configurations/#{runtime_key}")

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
      |> api_get(~p"/api/v2/site/app-configurations")

    assert %{"app_configurations" => entries} = json_response(conn, 200)
    refute Enum.any?(entries, &(&1["key"] == runtime_key))
  end

  test "a rejected structured value names the failing field", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> api_put(~p"/api/v2/site/app-configurations/groups/brain", %{
        "values" => %{
          "brain.embedding_model" => %{
            "provider_id" => "",
            "model" => "text-embedding",
            "dimensions" => 1024
          }
        },
        "reset_keys" => []
      })

    assert %{
             "errors" => [
               %{
                 "detail" => "brain.embedding_model: provider_id is invalid",
                 "meta" => %{
                   "details" => [
                     %{"path" => "brain.embedding_model.provider_id", "message" => "is invalid"}
                   ]
                 }
               }
             ]
           } = json_response(conn, 422)
  end

  test "unknown AppConfigure keys are not writable through the console API", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> api_put(~p"/api/v2/site/app-configurations/not.registered", %{"value" => "value"})

    assert %{"errors" => [%{"code" => "not_found"}]} = json_response(conn, 404)
  end

  test "setup-owned AppConfigure keys are visible but not writable through the console API", %{
    conn: conn
  } do
    assert {:ok, "ABCDEFGH"} = SetupConfig.put_bootstrap_activation_code("ABCDEFGH")
    conn = console_conn(conn)

    conn = api_get(conn, ~p"/api/v2/site/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)

    assert %{"editable" => false, "value" => true} = entry(entries, "setup.completed")

    assert %{"editable" => false, "value" => "ABCDEFGH"} =
             entry(entries, "setup.bootstrap_activation_code")

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/site/app-configurations/setup.completed", %{"value" => false})

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> api_delete(~p"/api/v2/site/app-configurations/setup.bootstrap_activation_code")

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)
    assert {:ok, true} = SetupConfig.completed?()
    assert {:ok, "ABCDEFGH"} = SetupConfig.bootstrap_activation_code()
  end

  test "Plugin selection stays readable but writes use the Plugin controls", %{conn: conn} do
    enabled = ["china-market-ai-providers", "vercel-worker-provider"]
    assert {:ok, ^enabled} = Ankole.Plugins.put_enabled_ids(enabled)
    conn = console_conn(conn)

    entries =
      conn
      |> api_get(~p"/api/v2/site/app-configurations")
      |> json_response(200)
      |> Map.fetch!("app_configurations")

    assert %{"editable" => false, "value" => ^enabled} = entry(entries, "plugins.enabled_ids")

    for rejected <- [
          conn
          |> recycle_api()
          |> api_put(~p"/api/v2/site/app-configurations/plugins.enabled_ids", %{"value" => []}),
          conn
          |> recycle_api()
          |> api_delete(~p"/api/v2/site/app-configurations/plugins.enabled_ids")
        ] do
      assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(rejected, 422)
    end

    assert {:ok, ^enabled} = Ankole.Plugins.enabled_ids()

    conn
    |> recycle_api()
    |> api_put(~p"/api/v2/site/control-plane-plugins", %{
      "id" => "vercel-worker-provider",
      "enabled" => false
    })
    |> json_response(200)

    assert {:ok, ["china-market-ai-providers"]} = Ankole.Plugins.enabled_ids()
  end

  test "Installation-owned AppConfigure keys stay readable while their owner keeps writing them",
       %{conn: conn} do
    conn = console_conn(conn)

    conn = api_get(conn, ~p"/api/v2/site/app-configurations")
    assert %{"app_configurations" => entries} = json_response(conn, 200)
    assert %{"editable" => false} = entry(entries, "runtime_fabric.worker_auth_key")
    conn = conn |> recycle_api() |> api_get(~p"/api/v2/app-configurations")
    assert %{"app_configurations" => tenant_entries} = json_response(conn, 200)
    assert %{"editable" => false} = entry(tenant_entries, "principals.identity_providers.active")

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/app-configurations/principals.identity_providers.active", %{
        "value" => []
      })

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/site/app-configurations/runtime_fabric.worker_auth_key", %{
        "value" => "leaked"
      })

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)

    # Closing the Console path must not close the path the owning API uses.
    assert {:ok, %{"provider_id" => "local-console"}} =
             IdentityProviders.save_provider("local-console", "lark", %{
               "appID" => "cli_owner",
               "appSecret" => "secret"
             })
  end

  defp key(prefix, name), do: prefix <> "." <> name

  test "tenant setting updates, reveals, and resets keep the site value and other tenants isolated",
       %{conn: conn, prefix: prefix} do
    alias Ankole.Repo

    definition =
      AppConfigure.define(
        key: key(prefix, "tenant_secret"),
        scope: :tenant,
        encrypted: true,
        schema: Schema.new(fn value -> {:ok, value} end)
      )

    :ok = Registry.register_definitions([definition])
    assert {:ok, _} = AppConfigure.put_global_by_key(definition.key, "site secret")
    conn = console_conn(conn)

    assert %{"app_configuration" => %{"source" => "tenant"}} =
             conn
             |> api_put("/api/v2/app-configurations/#{definition.key}", %{value: "tenant secret"})
             |> json_response(200)

    %{"app_configuration" => item} =
      conn
      |> recycle_api()
      |> api_get("/api/v2/app-configurations/#{definition.key}")
      |> json_response(200)

    refute item["value"]

    assert %{"decrypted_value" => %{"value" => "tenant secret"}} =
             conn
             |> recycle_api()
             |> api_post("/api/v2/app-configurations/#{definition.key}/decryptions", %{})
             |> json_response(201)

    other = Ankole.DataCase.create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:ok, "site secret"} = AppConfigure.get_by_key(definition.key)
    end)

    assert %{"app_configuration" => %{"source" => "global"}} =
             conn
             |> recycle_api()
             |> api_delete("/api/v2/app-configurations/#{definition.key}")
             |> json_response(200)

    assert %{"decrypted_value" => %{"value" => "site secret"}} =
             conn
             |> recycle_api()
             |> api_post("/api/v2/app-configurations/#{definition.key}/decryptions", %{})
             |> json_response(201)
  end

  test "Pod-scoped i18n.default_locale is omitted from site settings and editable per tenant", %{
    conn: conn
  } do
    conn = console_conn(conn)

    site_entries =
      conn
      |> api_get("/api/v2/site/app-configurations")
      |> json_response(200)
      |> Map.fetch!("app_configurations")

    refute entry(site_entries, "i18n.default_locale")

    assert %{"errors" => [%{"code" => "pod_scope_only"}]} =
             conn
             |> recycle_api()
             |> api_get("/api/v2/site/app-configurations/i18n.default_locale")
             |> json_response(422)

    assert %{"errors" => [%{"code" => "pod_scope_only"}]} =
             conn
             |> recycle_api()
             |> api_put("/api/v2/site/app-configurations/i18n.default_locale", %{
               "value" => "zh-Hans-CN"
             })
             |> json_response(422)

    tenant_entries =
      conn
      |> recycle_api()
      |> api_get("/api/v2/app-configurations")
      |> json_response(200)
      |> Map.fetch!("app_configurations")

    assert %{
             "scope" => "pod",
             "editable" => true,
             "value" => "en-US",
             "source" => "default"
           } = entry(tenant_entries, "i18n.default_locale")

    assert %{
             "app_configuration" => %{
               "key" => "i18n.default_locale",
               "scope" => "pod",
               "value" => "ja-JP",
               "source" => "tenant",
               "overridden" => true
             }
           } =
             conn
             |> recycle_api()
             |> api_put("/api/v2/app-configurations/i18n.default_locale", %{"value" => "ja-JP"})
             |> json_response(200)

    assert %{
             "app_configuration" => %{
               "value" => "en-US",
               "source" => "default",
               "overridden" => false
             }
           } =
             conn
             |> recycle_api()
             |> api_delete("/api/v2/app-configurations/i18n.default_locale")
             |> json_response(200)
  end

  defp entry(entries, key) do
    Enum.find(entries, &(&1["key"] == key))
  end

  defp json_api(conn),
    do:
      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

  defp api_get(conn, path), do: conn |> json_api() |> get(path)
  defp api_delete(conn, path), do: conn |> json_api() |> delete(path)

  defp api_put(conn, path, attrs),
    do: conn |> json_api() |> put(path, Jason.encode!(%{data: attrs}))

  defp api_post(conn, path, attrs),
    do: conn |> json_api() |> post(path, Jason.encode!(%{data: attrs}))
end
