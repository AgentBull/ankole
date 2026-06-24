defmodule AnkoleWeb.AppConfigurationControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Schema
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    {:ok, prefix: "__test.console_api.#{System.unique_integer([:positive])}"}
  end

  test "missing bearer token returns 401 before OpenAPI body validation", %{conn: conn} do
    conn =
      put(conn, ~p"/api/app-configurations/anything", %{
        "unexpected" => true
      })

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "OpenAPI JSON is public and scoped to the console REST API", %{conn: conn} do
    conn = get(conn, ~p"/api/openapi.json")
    paths = json_response(conn, 200)["paths"]

    assert Map.has_key?(paths, "/api/app-configurations")
    assert Map.has_key?(paths, "/api/app-configurations/{key}")
    assert Map.has_key?(paths, "/api/app-configurations/{key}/decryptions")
    refute Enum.any?(Map.keys(paths), &String.starts_with?(&1, "/.internal-apis"))
  end

  test "bearer-authenticated invalid request bodies return the uniform 422 envelope", %{
    conn: conn
  } do
    conn = bearer_conn(conn)

    conn =
      put(conn, ~p"/api/app-configurations/anything", %{
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

    conn = get(conn, ~p"/api/app-configurations")
    assert %{"data" => entries} = json_response(conn, 200)

    assert %{"value" => 1, "source" => "default", "editable" => true} =
             entry(entries, definition.key)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/app-configurations/#{definition.key}", %{"value" => 7})

    assert %{
             "data" => %{
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
      |> get(~p"/api/app-configurations/#{definition.key}")

    assert %{"data" => %{"value" => 7, "source" => "global"}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/app-configurations/#{definition.key}")

    assert %{
             "data" => %{
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
      put(conn, ~p"/api/app-configurations/#{definition.key}", %{
        "value" => %{"apiKey" => "secret-api-key"}
      })

    assert %{"data" => encrypted_item} = json_response(conn, 200)
    assert encrypted_item["key"] == definition.key
    assert encrypted_item["encrypted"] == true
    assert encrypted_item["source"] == "global"
    refute Map.has_key?(encrypted_item, "value")

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/app-configurations/#{definition.key}")

    assert %{"data" => encrypted_detail} = json_response(conn, 200)
    refute Map.has_key?(encrypted_detail, "value")

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/app-configurations/#{definition.key}/decryptions", %{})

    assert %{
             "data" => %{
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

    conn = get(conn, ~p"/api/app-configurations")
    assert %{"data" => entries} = json_response(conn, 200)

    assert %{"kind" => "pattern", "editable" => false, "pattern" => pattern_source} =
             entry(entries, pattern.id)

    assert pattern_source == Regex.source(pattern.key_pattern)
    refute Enum.any?(entries, &(&1["key"] == runtime_key))

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/app-configurations/#{runtime_key}", %{"value" => %{"enabled" => true}})

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    assert {:ok, %{"enabled" => true}} =
             AppConfigure.put_global_by_key(runtime_key, %{"enabled" => true})

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/app-configurations")

    assert %{"data" => entries} = json_response(conn, 200)

    assert %{"kind" => "pattern_concrete", "editable" => true, "value" => %{"enabled" => true}} =
             entry(entries, runtime_key)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/app-configurations/#{runtime_key}", %{"value" => %{"enabled" => false}})

    assert %{"data" => %{"value" => %{"enabled" => false}}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/app-configurations/#{runtime_key}")

    assert %{"data" => %{"key" => ^runtime_key, "editable" => false, "overridden" => false}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/app-configurations")

    assert %{"data" => entries} = json_response(conn, 200)
    refute Enum.any?(entries, &(&1["key"] == runtime_key))
  end

  test "unknown AppConfigure keys are not writable through the console API", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/app-configurations/not.registered", %{"value" => "value"})

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  defp key(prefix, name), do: prefix <> "." <> name

  defp entry(entries, key) do
    Enum.find(entries, &(&1["key"] == key))
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
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("console-api-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
