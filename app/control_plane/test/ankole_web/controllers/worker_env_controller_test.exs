defmodule AnkoleWeb.WorkerEnvControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    {:ok, unique: System.unique_integer([:positive])}
  end

  test "missing browser session returns 401 before OpenAPI body validation", %{conn: conn} do
    conn = put(conn, ~p"/api/v1/site/worker-envs/ANYTHING", %{"unexpected" => true})

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "admin manages custom variables end to end", %{conn: conn, unique: unique} do
    name = "CTRL_CUSTOM_#{unique}"
    conn = console_conn(conn)

    conn =
      put(conn, ~p"/api/v1/site/worker-envs/#{name}", %{
        "value" => "plain-value",
        "description" => "registry mirror"
      })

    assert %{
             "worker_env" => %{
               "name" => ^name,
               "secret" => false,
               "value" => "plain-value",
               "source" => "global"
             }
           } = json_response(conn, 200)

    conn = conn |> recycle_api() |> get(~p"/api/v1/site/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    assert %{"value" => "plain-value", "description" => "registry mirror"} = entry(entries, name)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/site/worker-envs/#{name}")
    assert %{"worker_env" => %{"name" => ^name, "present" => false}} = json_response(conn, 200)

    conn = conn |> recycle_api() |> get(~p"/api/v1/site/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    refute entry(entries, name)
  end

  test "secret variables stay masked until decrypted", %{conn: conn, unique: unique} do
    name = "CTRL_SECRET_#{unique}"
    conn = console_conn(conn)

    conn =
      put(conn, ~p"/api/v1/site/worker-envs/#{name}", %{"value" => "hunter2", "secret" => true})

    assert %{"worker_env" => item} = json_response(conn, 200)
    assert item["secret"] == true
    refute Map.has_key?(item, "value")

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/site/worker-envs/#{name}", %{"description" => "metadata only"})

    assert %{"worker_env" => preserved} = json_response(conn, 200)
    assert preserved["secret"] == true
    assert preserved["description"] == "metadata only"
    refute Map.has_key?(preserved, "value")

    conn = conn |> recycle_api() |> post(~p"/api/v1/site/worker-envs/#{name}/decryptions", %{})

    assert %{"decrypted_value" => %{"name" => ^name, "value" => "hunter2"}} =
             json_response(conn, 200)
  end

  test "agent tier lists effective values and edits only the agent layer", %{
    conn: conn,
    unique: unique
  } do
    %{principal: agent} = agent_fixture()
    name = "CTRL_TIERED_#{unique}"
    conn = console_conn(conn)

    conn = put(conn, ~p"/api/v1/site/worker-envs/#{name}", %{"value" => "global-value"})
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

  test "reserved, malformed, and unknown names return stable errors", %{conn: conn} do
    conn = console_conn(conn)

    conn = put(conn, ~p"/api/v1/site/worker-envs/PATH", %{"value" => "/tmp"})
    assert %{"error" => %{"code" => "reserved_name"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> put(~p"/api/v1/site/worker-envs/bad-name", %{"value" => "x"})
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> put(~p"/api/v1/site/worker-envs/OK_NAME", %{"value" => 42})
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> put(~p"/api/v1/site/worker-envs/OK_NAME", %{})
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/site/worker-envs/MISSING_NAME")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

    conn =
      conn |> recycle_api() |> post(~p"/api/v1/site/worker-envs/MISSING_NAME/decryptions", %{})

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  defp entry(entries, name), do: Enum.find(entries, &(&1["name"] == name))
end
