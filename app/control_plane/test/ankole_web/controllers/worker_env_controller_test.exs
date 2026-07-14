defmodule AnkoleWeb.WorkerEnvControllerTest do
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

    {:ok, unique: System.unique_integer([:positive])}
  end

  test "missing bearer token returns 401 before OpenAPI body validation", %{conn: conn} do
    conn = put(conn, ~p"/api/v1/worker-envs/ANYTHING", %{"unexpected" => true})

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "OpenAPI JSON documents the worker env console routes", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/openapi.json")
    paths = json_response(conn, 200)["paths"]

    assert Map.has_key?(paths, "/api/v1/worker-envs")
    assert Map.has_key?(paths, "/api/v1/worker-envs/{name}")
    assert Map.has_key?(paths, "/api/v1/worker-envs/{name}/decryptions")
    assert Map.has_key?(paths, "/api/v1/agents/{agent_uid}/worker-envs")
    assert Map.has_key?(paths, "/api/v1/agents/{agent_uid}/worker-envs/{name}")
    assert Map.has_key?(paths, "/api/v1/agents/{agent_uid}/worker-envs/{name}/decryptions")
  end

  test "admin manages custom variables end to end", %{conn: conn, unique: unique} do
    name = "CTRL_CUSTOM_#{unique}"
    conn = bearer_conn(conn)

    conn =
      put(conn, ~p"/api/v1/worker-envs/#{name}", %{
        "value" => "plain-value",
        "description" => "registry mirror"
      })

    assert %{
             "worker_env" => %{
               "name" => ^name,
               "kind" => "custom",
               "secret" => false,
               "value" => "plain-value",
               "source" => "global"
             }
           } = json_response(conn, 200)

    conn = conn |> recycle_api() |> get(~p"/api/v1/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    assert %{"value" => "plain-value", "description" => "registry mirror"} = entry(entries, name)

    conn = conn |> recycle_api() |> get(~p"/api/v1/worker-envs/#{name}")
    assert %{"worker_env" => %{"value" => "plain-value"}} = json_response(conn, 200)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/worker-envs/#{name}")
    assert %{"worker_env" => %{"name" => ^name, "present" => false}} = json_response(conn, 200)

    conn = conn |> recycle_api() |> get(~p"/api/v1/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    refute entry(entries, name)
  end

  test "secret variables stay masked until decrypted", %{conn: conn, unique: unique} do
    name = "CTRL_SECRET_#{unique}"
    conn = bearer_conn(conn)

    conn =
      put(conn, ~p"/api/v1/worker-envs/#{name}", %{"value" => "hunter2", "secret" => true})

    assert %{"worker_env" => item} = json_response(conn, 200)
    assert item["secret"] == true
    refute Map.has_key?(item, "value")

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/worker-envs/#{name}", %{"description" => "metadata only"})

    assert %{"worker_env" => preserved} = json_response(conn, 200)
    assert preserved["secret"] == true
    assert preserved["description"] == "metadata only"
    refute Map.has_key?(preserved, "value")

    conn = conn |> recycle_api() |> post(~p"/api/v1/worker-envs/#{name}/decryptions", %{})

    assert %{"decrypted_value" => %{"name" => ^name, "value" => "hunter2"}} =
             json_response(conn, 200)
  end

  test "agent tier lists effective values and edits only the agent layer", %{
    conn: conn,
    unique: unique
  } do
    %{principal: agent} = agent_fixture()
    name = "CTRL_TIERED_#{unique}"
    conn = bearer_conn(conn)

    conn = put(conn, ~p"/api/v1/worker-envs/#{name}", %{"value" => "global-value"})
    assert %{"worker_env" => _item} = json_response(conn, 200)

    conn = conn |> recycle_api() |> get(~p"/api/v1/agents/#{agent.uid}/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    assert %{"source" => "global", "value" => "global-value"} = entry(entries, name)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/worker-envs/#{name}", %{
        "value" => "agent-value",
        "secret" => true
      })

    assert %{"worker_env" => %{"source" => "agent", "secret" => true}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/agents/#{agent.uid}/worker-envs/#{name}/decryptions", %{})

    assert %{"decrypted_value" => %{"value" => "agent-value"}} = json_response(conn, 200)

    conn =
      conn |> recycle_api() |> delete(~p"/api/v1/agents/#{agent.uid}/worker-envs/#{name}")

    assert %{"worker_env" => %{"source" => "global", "value" => "global-value"}} =
             json_response(conn, 200)

    conn = conn |> recycle_api() |> get(~p"/api/v1/agents/agent-missing/worker-envs")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "declared names route through AppConfigure", %{conn: conn, unique: unique} do
    env_name = "CTRL_DECLARED_#{unique}"

    definition =
      AppConfigure.define(
        key: "__test.worker_env_controller.#{unique}",
        encrypted: false,
        schema: Schema.string(),
        default_value: "compiled-default",
        description: "Declared export",
        worker_env_name: env_name
      )

    assert :ok = AppConfigure.register_definitions([definition])
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/worker-envs/#{env_name}")

    assert %{
             "worker_env" => %{
               "kind" => "declared",
               "source" => "default",
               "value" => "compiled-default",
               "declared_key" => declared_key
             }
           } = json_response(conn, 200)

    assert declared_key == definition.key

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/worker-envs/#{env_name}", %{"value" => "declared-global"})

    assert %{"worker_env" => %{"kind" => "declared", "source" => "global"}} =
             json_response(conn, 200)

    assert {:ok, "declared-global"} = AppConfigure.get_by_key(definition.key)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/worker-envs/#{env_name}")

    assert %{"worker_env" => %{"source" => "default", "value" => "compiled-default"}} =
             json_response(conn, 200)
  end

  test "reserved, malformed, and unknown names return stable errors", %{conn: conn} do
    conn = bearer_conn(conn)

    conn = put(conn, ~p"/api/v1/worker-envs/PATH", %{"value" => "/tmp"})
    assert %{"error" => %{"code" => "reserved_name"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> put(~p"/api/v1/worker-envs/bad-name", %{"value" => "x"})
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> put(~p"/api/v1/worker-envs/OK_NAME", %{"value" => 42})
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> put(~p"/api/v1/worker-envs/OK_NAME", %{})
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> get(~p"/api/v1/worker-envs/MISSING_NAME")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/worker-envs/MISSING_NAME")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn = conn |> recycle_api() |> post(~p"/api/v1/worker-envs/MISSING_NAME/decryptions", %{})
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  defp entry(entries, name), do: Enum.find(entries, &(&1["name"] == name))

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
    human = human_fixture(%{uid: unique_uid("worker-env-admin")})
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
