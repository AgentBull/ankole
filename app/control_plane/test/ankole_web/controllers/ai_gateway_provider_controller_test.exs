defmodule AnkoleWeb.AIGatewayProviderControllerTest do
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

  test "admin configures provider rows and agent model profiles through the console API", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn = get(conn, ~p"/api/v1/ai-gateway/provider-kinds")
    assert %{"provider_kinds" => sources} = json_response(conn, 200)
    openrouter = Enum.find(sources, &(&1["provider_kind"] == "openrouter"))
    openai_compatible = Enum.find(sources, &(&1["provider_kind"] == "openai_compatible"))
    azure_openai = Enum.find(sources, &(&1["provider_kind"] == "azure_openai"))
    parallel = Enum.find(sources, &(&1["provider_kind"] == "parallel"))
    jina_search = Enum.find(sources, &(&1["provider_kind"] == "jina_search"))
    jina_reader = Enum.find(sources, &(&1["provider_kind"] == "jina_reader"))

    assert "llm" in openrouter["capabilities"]
    assert "embedding" in openrouter["capabilities"]
    assert "rerank" in openrouter["capabilities"]

    openrouter_settings = Map.new(openrouter["settings"], &{&1["key"], &1})

    assert openrouter_settings["api_key"]["advanced"] == false
    assert openrouter_settings["base_url"]["advanced"] == true
    assert openrouter_settings["headers"]["advanced"] == true
    assert openrouter_settings["query_params"]["advanced"] == true
    assert openrouter_settings["app_referer"]["advanced"] == true
    assert openrouter_settings["app_title"]["advanced"] == true

    assert openrouter_settings["reasoningEffort"] == %{
             "key" => "reasoningEffort",
             "type" => "select",
             "default" => "high",
             "options" => ~w(none minimal low medium high xhigh),
             "required" => false,
             "encrypted" => false,
             "advanced" => false,
             "scope" => "request"
           }

    assert openrouter_settings["strictJSONSchema"]["advanced"] == true
    refute Map.has_key?(openrouter_settings, "reasoning")

    assert Enum.all?(sources, fn source ->
             Enum.all?(source["settings"], &is_boolean(&1["advanced"]))
           end)

    assert "web_search" in parallel["capabilities"]
    assert "web_fetch" in parallel["capabilities"]
    assert "web_search" in jina_search["capabilities"]
    assert "web_fetch" in jina_reader["capabilities"]

    assert "transport" in openai_compatible["connection_options"]
    assert is_nil(azure_openai["default_base_url"])
    assert "transport" in azure_openai["connection_options"]
    refute Map.has_key?(openrouter, "default_transport")

    refute Enum.any?(sources, &(&1["provider_kind"] == "gemini"))

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/ai-gateway/providers/openrouter-main", %{
        "provider_kind" => "openrouter",
        "connection_options" => %{"api_key" => "sk-test"}
      })

    assert %{
             "ai_gateway_provider" => %{
               "provider_id" => "openrouter-main",
               "provider_kind" => "openrouter",
               "encrypted_options" => %{
                 "api_key" => %{"present" => true, "masked" => "********"}
               }
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "sk-test"

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/ai-gateway/providers")

    assert %{"ai_gateway_providers" => providers} = json_response(conn, 200)
    assert Enum.any?(providers, &(&1["provider_id"] == "openrouter-main"))

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/model-profiles/primary", %{
        "provider_id" => "openrouter-main",
        "model" => "z-ai/glm-5.2",
        "context_length" => 1_048_576,
        "provider_options" => %{"reasoningEffort" => "medium"}
      })

    assert %{
             "model_profile" => %{
               "profile" => "primary",
               "configured" => true,
               "provider_id" => "openrouter-main",
               "model" => "z-ai/glm-5.2",
               "context_length" => 1_048_576
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/#{agent.uid}/model-profiles")

    assert %{
             "model_profiles" => %{
               "primary" => %{
                 "provider_id" => "openrouter-main",
                 "model" => "z-ai/glm-5.2",
                 "context_length" => 1_048_576
               }
             }
           } = json_response(conn, 200)

    assert {:ok, runtime_profile} = ModelProfiles.resolve_runtime_profile(agent.uid, "primary")
    assert runtime_profile["provider_id"] == "openrouter-main"
    assert runtime_profile["model"] == "z-ai/glm-5.2"
    assert runtime_profile["context_length"] == 1_048_576

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/ai-gateway/providers/openrouter-main")

    assert %{"error" => %{"code" => "provider_in_use"}} = json_response(conn, 422)
  end

  test "provider writes reject body provider_id drift from the path", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/ai-gateway/providers/openrouter-main", %{
        "provider_id" => "other-provider",
        "provider_kind" => "openrouter"
      })

    assert %{"error" => %{"code" => "provider_id_mismatch"}} = json_response(conn, 422)
  end

  test "admin manages named Codex accounts and assigns one through the coding model profile", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)
    auth_json = codex_auth_json("chatgpt-account-1", "initial-token")

    conn =
      post(conn, ~p"/api/v1/codex-accounts", %{
        "name" => "Primary ChatGPT",
        "auth_json" => auth_json
      })

    assert %{
             "codex_account" => %{
               "account_id" => "chatgpt-account-1",
               "name" => "Primary ChatGPT",
               "auth_hash" => auth_hash
             }
           } = json_response(conn, 200)

    assert is_binary(auth_hash)
    refute conn.resp_body =~ "initial-token"

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/model-profiles/coding", %{
        "codex_account_id" => "chatgpt-account-1"
      })

    assert %{
             "model_profile" => %{
               "profile" => "coding",
               "configured" => true,
               "codex_account_id" => "chatgpt-account-1"
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/codex-accounts/chatgpt-account-1", %{
        "name" => "Primary subscription",
        "auth_json" => codex_auth_json("chatgpt-account-1", "refreshed-token")
      })

    assert %{
             "codex_account" => %{
               "name" => "Primary subscription",
               "auth_hash" => refreshed_hash
             }
           } = json_response(conn, 200)

    refute refreshed_hash == auth_hash
    refute conn.resp_body =~ "refreshed-token"

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/codex-accounts/chatgpt-account-1")

    assert %{"error" => %{"code" => "codex_account_in_use"}} = json_response(conn, 422)
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

  defp codex_auth_json(account_id, access_token) do
    Ankole.JSON.encode!(%{
      "tokens" => %{
        "access_token" => access_token,
        "account_id" => account_id,
        "id_token" => "id-token",
        "refresh_token" => "refresh-token"
      }
    })
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
