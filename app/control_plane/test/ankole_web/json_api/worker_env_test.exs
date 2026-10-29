defmodule AnkoleWeb.JSONAPI.WorkerEnvTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    {:ok, unique: System.unique_integer([:positive])}
  end

  test "missing browser session returns 401 before OpenAPI body validation", %{conn: conn} do
    conn = api_put(conn, ~p"/api/v2/site/worker-envs/ANYTHING", %{"unexpected" => true})

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "admin manages custom variables end to end", %{conn: conn, unique: unique} do
    name = "CTRL_CUSTOM_#{unique}"
    conn = console_conn(conn)

    conn =
      api_put(conn, ~p"/api/v2/site/worker-envs/#{name}", %{
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

    conn = conn |> recycle_api() |> api_get(~p"/api/v2/site/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    assert %{"value" => "plain-value", "description" => "registry mirror"} = entry(entries, name)

    conn = conn |> recycle_api() |> api_delete(~p"/api/v2/site/worker-envs/#{name}")
    assert %{"worker_env" => %{"name" => ^name, "present" => false}} = json_response(conn, 200)

    conn = conn |> recycle_api() |> api_get(~p"/api/v2/site/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    refute entry(entries, name)
  end

  test "secret variables stay masked until decrypted", %{conn: conn, unique: unique} do
    name = "CTRL_SECRET_#{unique}"
    conn = console_conn(conn)

    conn =
      api_put(conn, ~p"/api/v2/site/worker-envs/#{name}", %{
        "value" => "hunter2",
        "secret" => true
      })

    assert %{"worker_env" => item} = json_response(conn, 200)
    assert item["secret"] == true
    refute Map.has_key?(item, "value")

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/site/worker-envs/#{name}", %{"description" => "metadata only"})

    assert %{"worker_env" => preserved} = json_response(conn, 200)
    assert preserved["secret"] == true
    assert preserved["description"] == "metadata only"
    refute Map.has_key?(preserved, "value")

    conn =
      conn |> recycle_api() |> api_post(~p"/api/v2/site/worker-envs/#{name}/decryptions", %{})

    assert %{"decrypted_value" => %{"name" => ^name, "value" => "hunter2"}} =
             json_response(conn, 201)
  end

  test "agent tier lists effective values and edits only the agent layer", %{
    conn: conn,
    unique: unique
  } do
    %{principal: agent} = agent_fixture()
    name = "CTRL_TIERED_#{unique}"
    conn = console_conn(conn)

    conn = api_put(conn, ~p"/api/v2/site/worker-envs/#{name}", %{"value" => "global-value"})
    assert %{"worker_env" => _item} = json_response(conn, 200)

    conn = conn |> recycle_api() |> api_get(~p"/api/v2/agents/#{agent.uid}/worker-envs")
    assert %{"worker_envs" => entries} = json_response(conn, 200)
    assert %{"source" => "global", "value" => "global-value"} = entry(entries, name)

    conn =
      conn
      |> recycle_api()
      |> api_put(~p"/api/v2/agents/#{agent.uid}/worker-envs/#{name}", %{
        "value" => "agent-value",
        "secret" => true
      })

    assert %{"worker_env" => %{"source" => "agent", "secret" => true}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> api_post(~p"/api/v2/agents/#{agent.uid}/worker-envs/#{name}/decryptions", %{})

    assert %{"decrypted_value" => %{"value" => "agent-value"}} = json_response(conn, 201)

    conn =
      conn |> recycle_api() |> api_delete(~p"/api/v2/agents/#{agent.uid}/worker-envs/#{name}")

    assert %{"worker_env" => %{"source" => "global", "value" => "global-value"}} =
             json_response(conn, 200)

    conn = conn |> recycle_api() |> api_get(~p"/api/v2/agents/agent-missing/worker-envs")
    assert %{"errors" => [%{"code" => "not_found"}]} = json_response(conn, 404)
  end

  test "reserved, malformed, and unknown names return stable errors", %{conn: conn} do
    conn = console_conn(conn)

    conn = api_put(conn, ~p"/api/v2/site/worker-envs/PATH", %{"value" => "/tmp"})

    assert %{"errors" => [%{"code" => "reserved_worker_env_name", "detail" => detail}]} =
             json_response(conn, 422)

    assert detail =~ "reserved"

    conn =
      conn |> recycle_api() |> api_put(~p"/api/v2/site/worker-envs/bad-name", %{"value" => "x"})

    assert %{"errors" => [_ | _]} = json_response(conn, 422)

    conn =
      conn |> recycle_api() |> api_put(~p"/api/v2/site/worker-envs/OK_NAME", %{"value" => 42})

    assert %{"errors" => [_ | _]} = json_response(conn, 400)

    conn = conn |> recycle_api() |> api_put(~p"/api/v2/site/worker-envs/OK_NAME", %{})
    assert %{"errors" => [_ | _]} = json_response(conn, 422)

    conn = conn |> recycle_api() |> api_delete(~p"/api/v2/site/worker-envs/MISSING_NAME")
    assert %{"errors" => [%{"code" => "not_found"}]} = json_response(conn, 404)

    conn =
      conn
      |> recycle_api()
      |> api_post(~p"/api/v2/site/worker-envs/MISSING_NAME/decryptions", %{})

    assert %{"errors" => [%{"code" => "not_found"}]} = json_response(conn, 404)
  end

  test "tenant overrides stay in the selected tenant and reset to inherited site values", %{
    conn: conn,
    unique: unique
  } do
    alias Ankole.{Repo, AgentWorkers.WorkerEnv}
    name = "TENANT_#{unique}"
    conn = console_conn(conn)

    assert %{"worker_env" => %{}} =
             conn
             |> api_put("/api/v2/site/worker-envs/#{name}", %{value: "site", secret: true})
             |> json_response(200)

    assert %{"worker_env" => %{"source" => "tenant"}} =
             conn
             |> recycle_api()
             |> api_put("/api/v2/worker-envs/#{name}", %{value: "tenant", secret: true})
             |> json_response(200)

    assert %{"decrypted_value" => %{"value" => "tenant"}} =
             conn
             |> recycle_api()
             |> api_post("/api/v2/worker-envs/#{name}/decryptions", %{})
             |> json_response(201)

    other = Ankole.DataCase.create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:ok, _} =
               WorkerEnv.console_put_tenant("OTHER_ONLY_#{unique}", %{"value" => "other"})
    end)

    %{"worker_envs" => items} =
      conn |> recycle_api() |> api_get("/api/v2/worker-envs") |> json_response(200)

    refute entry(items, "OTHER_ONLY_#{unique}")

    assert %{"worker_env" => %{"source" => "global", "secret" => true}} =
             conn
             |> recycle_api()
             |> api_delete("/api/v2/worker-envs/#{name}")
             |> json_response(200)

    assert %{"decrypted_value" => %{"value" => "site"}} =
             conn
             |> recycle_api()
             |> api_post("/api/v2/worker-envs/#{name}/decryptions", %{})
             |> json_response(201)
  end

  defp entry(entries, name), do: Enum.find(entries, &(&1["name"] == name))

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
