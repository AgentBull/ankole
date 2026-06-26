defmodule AnkoleWeb.LlmProviderControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
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

    :ok
  end

  test "OpenAPI JSON includes operator LLM runtime configuration endpoints", %{conn: conn} do
    conn = get(conn, ~p"/api/openapi.json")
    paths = json_response(conn, 200)["paths"]

    assert Map.has_key?(paths, "/api/llm-provider-sources")
    assert Map.has_key?(paths, "/api/llm-providers")
    assert Map.has_key?(paths, "/api/llm-providers/{provider_id}")
    assert Map.has_key?(paths, "/api/agents/{agent_uid}/model-profiles")
    assert Map.has_key?(paths, "/api/agents/{agent_uid}/model-profiles/{profile}")
  end

  test "admin configures provider rows and agent model profiles through the console API", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/llm-provider-sources")
    assert %{"data" => sources} = json_response(conn, 200)
    assert Enum.find(sources, &(&1["provider_source"] == "openrouter"))["codex_compatible"]

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/llm-providers/openrouter-main", %{
        "provider_source" => "openrouter",
        "credential" => "sk-test",
        "connection_options" => %{"include_usage" => true}
      })

    assert %{
             "data" => %{
               "provider_id" => "openrouter-main",
               "provider_source" => "openrouter",
               "credential" => %{"present" => true, "masked" => "********"}
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "sk-test"

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/llm-providers")

    assert %{"data" => providers} = json_response(conn, 200)
    assert Enum.any?(providers, &(&1["provider_id"] == "openrouter-main"))

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/agents/#{agent.uid}/model-profiles/primary", %{
        "provider_id" => "openrouter-main",
        "model" => "z-ai/glm-5.2",
        "provider_options" => %{"reasoningEffort" => "medium"}
      })

    assert %{
             "data" => %{
               "profile" => "primary",
               "configured" => true,
               "provider_id" => "openrouter-main",
               "model" => "z-ai/glm-5.2"
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/agents/#{agent.uid}/model-profiles")

    assert %{
             "data" => %{
               "primary" => %{
                 "provider_id" => "openrouter-main",
                 "model" => "z-ai/glm-5.2"
               }
             }
           } = json_response(conn, 200)

    assert {:ok, runtime_profile} = ModelProfiles.resolve_runtime_profile(agent.uid, "primary")
    assert runtime_profile["provider_id"] == "openrouter-main"
    assert runtime_profile["model"] == "z-ai/glm-5.2"

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/llm-providers/openrouter-main")

    assert %{"error" => %{"code" => "provider_in_use"}} = json_response(conn, 422)
  end

  test "provider writes reject body provider_id drift from the path", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/llm-providers/openrouter-main", %{
        "provider_id" => "other-provider",
        "provider_source" => "openrouter"
      })

    assert %{"error" => %{"code" => "provider_id_mismatch"}} = json_response(conn, 422)
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
    human = human_fixture(%{uid: unique_uid("llm-console-admin")})
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
