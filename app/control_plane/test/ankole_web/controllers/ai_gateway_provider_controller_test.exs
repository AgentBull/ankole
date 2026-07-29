defmodule AnkoleWeb.AIGatewayProviderControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderConfigs
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
    ModelMetadataCache.clear_for_test()

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
    assert openrouter_settings["api_key"]["scope"] == "credential"
    assert openrouter_settings["base_url"]["advanced"] == true
    assert openrouter_settings["headers"]["advanced"] == true
    assert openrouter_settings["query_params"]["advanced"] == true
    assert openrouter_settings["app_referer"]["advanced"] == true
    assert openrouter_settings["app_title"]["advanced"] == true

    assert openrouter_settings["reasoningEffort"] == %{
             "key" => "reasoningEffort",
             "type" => "select",
             "default" => "high",
             "options" => ~w(none minimal low medium high xhigh max ultra),
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
        "credential_pool" => %{
          "entries" => [%{"label" => "Primary key", "api_key" => "sk-test"}]
        }
      })

    assert %{
             "ai_gateway_provider" => %{
               "provider_id" => "openrouter-main",
               "provider_kind" => "openrouter",
               "credential_pool" => %{
                 "strategy" => "fill_first",
                 "entries" => [
                   %{
                     "label" => "Primary key",
                     "credential_present" => true,
                     "status" => "ok"
                   }
                 ]
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

  test "admin disables an active provider and deletes it on the next request", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/ai-gateway/providers/openrouter-unused", %{
        "provider_kind" => "openrouter",
        "credential_pool" => %{
          "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
        }
      })

    assert %{"ai_gateway_provider" => %{"disabled_at" => nil}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/ai-gateway/providers/openrouter-unused")

    assert %{"ai_gateway_provider" => %{"disabled_at" => disabled_at}} = json_response(conn, 200)
    assert is_binary(disabled_at)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/ai-gateway/providers/openrouter-unused")

    assert %{"ai_gateway_provider" => %{"provider_id" => "openrouter-unused"}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/ai-gateway/providers")

    assert %{"ai_gateway_providers" => providers} = json_response(conn, 200)
    refute Enum.any?(providers, &(&1["provider_id"] == "openrouter-unused"))
  end

  test "image profiles reject catalog candidates without definitive endpoints", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    provider_id = "openrouter-image-profile"

    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/ai-gateway/providers/#{provider_id}", %{
        "provider_kind" => "openrouter",
        "credential_pool" => %{
          "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
        }
      })

    assert %{"ai_gateway_provider" => %{"provider_id" => ^provider_id}} =
             json_response(conn, 200)

    :ok =
      ModelMetadataCache.put(
        {:model_metadata_source, provider_id, :openrouter, "models?output_modalities=all"},
        [
          %{
            "id" => "openrouter/auto",
            "name" => "OpenRouter Auto",
            "architecture" => %{"output_modalities" => ["image"]}
          },
          %{
            "id" => "google/gemini-3.1-flash-lite-image",
            "name" => "Gemini Flash Image",
            "architecture" => %{"output_modalities" => ["image"]}
          }
        ],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_catalog, provider_id, "images/models"},
        [
          %{"id" => "openrouter/auto"},
          %{"id" => "google/gemini-3.1-flash-lite-image"}
        ],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, provider_id, "images/models/openrouter/auto/endpoints"},
        [],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, provider_id,
         "images/models/google/gemini-3.1-flash-lite-image/endpoints"},
        [
          %{
            "provider_slug" => "google",
            "provider_tag" => "google/gemini-3.1-flash-lite-image:google",
            "supported_parameters" => %{}
          }
        ],
        60_000
      )

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/ai-gateway/models")

    assert %{"data" => candidates} = json_response(conn, 200)
    assert Enum.any?(candidates, &(&1["id"] == "#{provider_id}/openrouter/auto"))

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/model-profiles/image_generate", %{
        "provider_id" => provider_id,
        "model" => "openrouter/auto"
      })

    assert %{
             "error" => %{
               "code" => "image_model_unavailable",
               "message" => "selected image model has no usable image-generation endpoint"
             }
           } = json_response(conn, 422)

    assert {:error, :model_profile_not_configured} =
             ModelProfiles.get_model_profile(agent.uid, "image_generate")

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/model-profiles/image_generate", %{
        "provider_id" => provider_id,
        "model" => "google/gemini-3.1-flash-lite-image"
      })

    assert %{
             "model_profile" => %{
               "configured" => true,
               "model" => "google/gemini-3.1-flash-lite-image",
               "provider_id" => ^provider_id
             }
           } = json_response(conn, 200)
  end

  test "admin manages a ChatGPT credential pool and assigns its provider to coding", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn =
      put(conn, ~p"/api/v1/ai-gateway/providers/chatgpt-main", %{
        "provider_kind" => "chatgpt_subscription"
      })

    assert %{
             "ai_gateway_provider" => %{
               "provider_id" => "chatgpt-main",
               "provider_kind" => "chatgpt_subscription",
               "credential_pool" => %{"entries" => []}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/ai-gateway/providers/chatgpt-main/chatgpt-enterprise-credentials", %{
        "id" => "enterprise-1",
        "label" => "Primary ChatGPT",
        "access_token" => "enterprise-secret",
        "account_id" => "chatgpt-account-1",
        "plan_type" => "enterprise"
      })

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "strategy" => "fill_first",
                 "entries" => [
                   %{
                     "id" => "enterprise-1",
                     "label" => "Primary ChatGPT",
                     "account_id" => "chatgpt-account-1",
                     "plan_type" => "enterprise",
                     "auth_type" => "enterprise_access_token",
                     "credential_present" => true,
                     "status" => "ok"
                   }
                 ]
               }
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "enterprise-secret"

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/ai-gateway/providers/chatgpt-main/chatgpt-enterprise-credentials", %{
        "id" => "enterprise-2",
        "label" => "Backup ChatGPT",
        "access_token" => "backup-secret",
        "account_id" => "chatgpt-account-2"
      })

    assert %{"ai_gateway_provider" => %{"credential_pool" => %{"entries" => entries}}} =
             json_response(conn, 200)

    assert Enum.map(entries, & &1["id"]) == ["enterprise-1", "enterprise-2"]

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/ai-gateway/providers/chatgpt-main/credential-pool/strategy", %{
        "strategy" => "round_robin"
      })

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{"strategy" => "round_robin"}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/agents/#{agent.uid}/model-profiles/coding", %{
        "provider_id" => "chatgpt-main",
        "model" => "gpt-5.6-sol",
        "provider_options" => %{
          "reasoningEffort" => "max",
          "serviceTier" => "priority"
        }
      })

    assert %{
             "model_profile" => %{
               "profile" => "coding",
               "configured" => true,
               "provider_id" => "chatgpt-main",
               "model" => "gpt-5.6-sol",
               "provider_options" => %{
                 "reasoningEffort" => "max",
                 "serviceTier" => "priority"
               }
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/ai-gateway/providers/chatgpt-main")

    assert %{
             "ai_gateway_provider" => %{
               "provider_id" => "chatgpt-main",
               "credential_pool" => %{"strategy" => "round_robin", "entries" => entries}
             }
           } = json_response(conn, 200)

    assert length(entries) == 2

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/ai-gateway/providers/chatgpt-main/credentials/enterprise-2")

    assert %{"ai_gateway_provider" => %{"credential_pool" => %{"entries" => [remaining]}}} =
             json_response(conn, 200)

    assert remaining["id"] == "enterprise-1"
  end

  test "admin adds, updates, disables, and enables a generic pool credential", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/ai-gateway/providers/openrouter-pool-admin", %{
        "provider_kind" => "openrouter",
        "credential_pool" => %{"entries" => []}
      })

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{"entries" => []}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/ai-gateway/providers/openrouter-pool-admin/credentials", %{
        "id" => "key-1",
        "label" => "Primary",
        "priority" => 2,
        "api_key" => "sk-original"
      })

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [
                   %{
                     "id" => "key-1",
                     "label" => "Primary",
                     "source" => "manual",
                     "priority" => 2,
                     "disabled_at" => nil,
                     "credential_present" => true,
                     "status" => "ok",
                     "request_count" => 0,
                     "last_selected_at" => nil
                   }
                 ]
               }
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "sk-original"

    disabled_at = DateTime.utc_now(:second) |> DateTime.to_iso8601()

    conn =
      conn
      |> recycle_api()
      |> put(
        ~p"/api/v1/ai-gateway/providers/openrouter-pool-admin/credentials/key-1",
        %{"label" => "Primary renamed", "disabled_at" => disabled_at}
      )

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [
                   %{
                     "label" => "Primary renamed",
                     "disabled_at" => ^disabled_at,
                     "credential_present" => true,
                     "status" => "disabled"
                   }
                 ]
               }
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "sk-original"

    conn =
      conn
      |> recycle_api()
      |> put(
        ~p"/api/v1/ai-gateway/providers/openrouter-pool-admin/credentials/key-1",
        %{"disabled_at" => nil}
      )

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [
                   %{
                     "disabled_at" => nil,
                     "credential_present" => true,
                     "status" => "ok"
                   }
                 ]
               }
             }
           } = json_response(conn, 200)

    assert {:ok, provider} = ProviderConfigs.fetch_provider("openrouter-pool-admin")
    assert {:ok, %{"api_key" => "sk-original"}} = ProviderConfigs.runtime_connection(provider)
  end

  test "credential metadata updates do not clear dead health", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/ai-gateway/providers/openrouter-dead-update", %{
        "provider_kind" => "openrouter",
        "credential_pool" => %{
          "entries" => [
            %{"id" => "dead-key", "label" => "Original", "api_key" => "sk-original"}
          ]
        }
      })

    assert %{"ai_gateway_provider" => %{"provider_id" => "openrouter-dead-update"}} =
             json_response(conn, 200)

    assert {:ok, provider} = ProviderConfigs.fetch_provider("openrouter-dead-update")
    :ok = CredentialPool.mark_dead(provider.id, "dead-key", %{"code" => "token_revoked"})

    conn =
      conn
      |> recycle_api()
      |> put(
        ~p"/api/v1/ai-gateway/providers/openrouter-dead-update/credentials/dead-key",
        %{"label" => "Renamed"}
      )

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [%{"label" => "Renamed", "status" => "dead"}]
               }
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put(
        ~p"/api/v1/ai-gateway/providers/openrouter-dead-update/credentials/dead-key",
        %{"api_key" => "sk-reauthenticated"}
      )

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{"entries" => [%{"status" => "ok"}]}
             }
           } = json_response(conn, 200)

    assert {:ok, provider} = ProviderConfigs.fetch_provider("openrouter-dead-update")

    assert {:ok, %{"api_key" => "sk-reauthenticated"}} =
             ProviderConfigs.runtime_connection(provider)
  end

  test "ChatGPT device login completes through the Console API without exposing tokens", %{
    conn: conn
  } do
    test_pid = self()
    verifier = String.duplicate("v", 64)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    id_token =
      jwt(%{
        "email" => "operator@example.com",
        "https://api.openai.com/auth" => %{
          "chatgpt_account_id" => "account-device",
          "chatgpt_plan_type" => "pro"
        }
      })

    issuer =
      start_upstream_server(fn request ->
        send(test_pid, {:chatgpt_auth_request, request})

        case request.path do
          "api/accounts/deviceauth/usercode" ->
            {:json, 200,
             %{
               "device_auth_id" => "device-auth-1",
               "user_code" => "ABCD-EFGH",
               "interval" => 1
             }}

          "api/accounts/deviceauth/token" ->
            {:json, 200,
             %{
               "authorization_code" => "authorization-code",
               "code_challenge" => challenge,
               "code_verifier" => verifier
             }}

          "oauth/token" ->
            {:json, 200,
             %{
               "access_token" => "access-secret",
               "refresh_token" => "refresh-secret",
               "id_token" => id_token
             }}
        end
      end)

    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/ai-gateway/providers/chatgpt-device", %{
        "provider_kind" => "chatgpt_subscription",
        "connection_options" => %{"auth_issuer" => issuer}
      })

    assert %{"ai_gateway_provider" => %{"provider_id" => "chatgpt-device"}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/ai-gateway/providers/chatgpt-device/chatgpt-login", %{
        "id" => "device-credential",
        "label" => "Device account",
        "priority" => 3
      })

    assert %{
             "mode" => "device",
             "user_code" => "ABCD-EFGH",
             "interval" => 1,
             "login_context" => login_context
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/ai-gateway/providers/chatgpt-device/chatgpt-login/poll", %{
        "login_context" => login_context
      })

    assert %{
             "status" => "complete",
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [
                   %{
                     "id" => "device-credential",
                     "label" => "Device account",
                     "source" => "device_oauth",
                     "priority" => 3,
                     "account_id" => "account-device",
                     "plan_type" => "pro",
                     "email" => "operator@example.com",
                     "auth_type" => "oauth",
                     "credential_present" => true,
                     "status" => "ok"
                   }
                 ]
               }
             }
           } = json_response(conn, 200)

    refute conn.resp_body =~ "access-secret"
    refute conn.resp_body =~ "refresh-secret"
    refute conn.resp_body =~ id_token

    assert_receive {:chatgpt_auth_request,
                    %{path: "api/accounts/deviceauth/usercode", body: user_code_body}}

    assert user_code_body == %{"client_id" => ChatGPTAuth.client_id()}

    assert_receive {:chatgpt_auth_request,
                    %{path: "api/accounts/deviceauth/token", body: poll_body}}

    assert poll_body == %{
             "device_auth_id" => "device-auth-1",
             "user_code" => "ABCD-EFGH"
           }

    assert_receive {:chatgpt_auth_request, %{path: "oauth/token", body: exchange_body}}

    assert exchange_body == %{
             "client_id" => ChatGPTAuth.client_id(),
             "code" => "authorization-code",
             "code_verifier" => verifier,
             "grant_type" => "authorization_code",
             "redirect_uri" => "#{issuer}/deviceauth/callback"
           }
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

  defp jwt(claims) do
    payload = claims |> Ankole.JSON.encode!() |> Base.url_encode64(padding: false)
    "e30.#{payload}.signature"
  end
end
