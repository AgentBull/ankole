defmodule AnkoleWeb.JSONAPI.ProviderModelsTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()
    ModelMetadataCache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "the Console catalog lists typed provider models without Agent aliases", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    for id <- ["catalog-a", "catalog-b"] do
      assert {:ok, _} =
               ProviderConfigs.create_provider(%{
                 provider_id: id,
                 provider_kind: "openai",
                 credential_pool: %{
                   "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
                 }
               })
    end

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "catalog-a",
               model: "gpt-4o-mini"
             })

    result = conn |> console_conn() |> send_v2(:get, ~p"/api/v2/site/ai-gateway/models")
    assert %{"models" => models} = json_response(result, 200)

    for id <- ["catalog-a", "catalog-b"] do
      assert %{"capability" => "llm", "image_input" => true} =
               Enum.find(models, &(&1["provider_id"] == id and &1["model"] == "gpt-4o-mini"))
    end

    refute Enum.any?(models, &(&1["model"] == "primary"))
    assert Enum.all?(models, &is_binary(&1["description"]))
  end

  test "admin creates, edits, lists, and deletes an Agent custom model profile", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-custom-console",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    conn =
      conn
      |> console_conn()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/model-profiles/kimi", %{
        "description" => "Long-context coding",
        "provider_id" => "openrouter-custom-console",
        "model" => "moonshotai/kimi-k2.7-code",
        "context_length" => 262_144,
        "provider_options" => %{"reasoningEffort" => "high"}
      })

    assert %{
             "model_profile" => %{
               "profile" => "kimi",
               "configured" => true,
               "description" => "Long-context coding",
               "provider_id" => "openrouter-custom-console",
               "model" => "moonshotai/kimi-k2.7-code"
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:get, ~p"/api/v2/agents/#{agent.uid}/model-profiles")

    assert %{"model_profiles" => %{"kimi" => %{"description" => "Long-context coding"}}} =
             json_response(conn, 200)

    missing_description =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/model-profiles/deepseek", %{
        "provider_id" => "openrouter-custom-console",
        "model" => "deepseek/deepseek-v3"
      })

    assert %{"errors" => [%{"code" => "missing", "detail" => "description is required"}]} =
             json_response(missing_description, 422)

    reserved_name =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/model-profiles/primary", %{
        "description" => "Reserved",
        "provider_id" => "openrouter-custom-console",
        "model" => "openai/gpt-5.4"
      })

    assert %{"errors" => [%{"code" => "fixed_model_profile_description_not_allowed"}]} =
             json_response(reserved_name, 422)

    invalid_name =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/model-profiles/Kimi", %{
        "description" => "Invalid uppercase name",
        "provider_id" => "openrouter-custom-console",
        "model" => "moonshotai/kimi-k2.7-code"
      })

    assert %{"errors" => [%{"code" => "invalid_model_profile"}]} =
             json_response(invalid_name, 422)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:delete, ~p"/api/v2/agents/#{agent.uid}/model-profiles/kimi")

    assert %{"model_profile" => %{"profile" => "kimi", "configured" => false}} =
             json_response(conn, 200)
  end

  test "image profiles reject catalog candidates without definitive endpoints", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    provider_id = "openrouter-image-profile"

    conn =
      conn
      |> console_conn()
      |> put_provider(provider_id, %{
        "provider_kind" => "openrouter",
        "credential_pool" => %{
          "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
        }
      })

    assert %{"ai_gateway_provider" => %{"provider_id" => ^provider_id}} = provider_json(conn)

    assert {:ok, provider} = ProviderConfigs.fetch_provider(provider_id)

    :ok =
      ModelMetadataCache.put(
        {:model_metadata_source, provider_id, provider.updated_at, :openrouter,
         "models?output_modalities=all"},
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
        {:image_model_catalog, provider_id, provider.updated_at, "images/models"},
        [
          %{"id" => "openrouter/auto"},
          %{"id" => "google/gemini-3.1-flash-lite-image"}
        ],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, provider_id, provider.updated_at,
         "images/models/openrouter/auto/endpoints"},
        [],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, provider_id, provider.updated_at,
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
      |> send_v2(:get, ~p"/api/v2/site/ai-gateway/models")

    assert %{"models" => candidates} = json_response(conn, 200)

    assert Enum.any?(
             candidates,
             &(&1["provider_id"] == provider_id and &1["model"] == "openrouter/auto")
           )

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/model-profiles/image_generate", %{
        "provider_id" => provider_id,
        "model" => "openrouter/auto"
      })

    assert %{
             "errors" => [
               %{
                 "code" => "image_model_unavailable",
                 "detail" => "selected image model has no usable image-generation endpoint"
               }
             ]
           } = json_response(conn, 422)

    assert {:error, :model_profile_not_configured} =
             ModelProfiles.get_model_profile(agent.uid, "image_generate")

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/model-profiles/image_generate", %{
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
    conn = console_conn(conn)

    conn = put_provider(conn, "chatgpt-main", %{"provider_kind" => "chatgpt_subscription"})

    assert %{
             "ai_gateway_provider" => %{
               "provider_id" => "chatgpt-main",
               "provider_kind" => "chatgpt_subscription",
               "credential_pool" => %{"entries" => []}
             }
           } = provider_json(conn)

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :post,
        ~p"/api/v2/site/ai-gateway/providers/chatgpt-main/chatgpt-enterprise-credentials",
        %{
          "id" => "enterprise-1",
          "label" => "Primary ChatGPT",
          "access_token" => "enterprise-secret",
          "account_id" => "chatgpt-account-1",
          "plan_type" => "enterprise"
        }
      )

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
           } = json_response(conn, 201)

    refute conn.resp_body =~ "enterprise-secret"

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :post,
        ~p"/api/v2/site/ai-gateway/providers/chatgpt-main/chatgpt-enterprise-credentials",
        %{
          "id" => "enterprise-2",
          "label" => "Backup ChatGPT",
          "access_token" => "backup-secret",
          "account_id" => "chatgpt-account-2"
        }
      )

    assert %{"ai_gateway_provider" => %{"credential_pool" => %{"entries" => entries}}} =
             json_response(conn, 201)

    assert Enum.map(entries, & &1["id"]) == ["enterprise-1", "enterprise-2"]

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :put,
        ~p"/api/v2/site/ai-gateway/providers/chatgpt-main/credential-pool/strategy",
        %{
          "strategy" => "round_robin"
        }
      )

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{"strategy" => "round_robin"}
             }
           } = provider_json(conn)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/model-profiles/coding", %{
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

    conn = show_provider(conn, "chatgpt-main")

    assert %{
             "ai_gateway_provider" => %{
               "provider_id" => "chatgpt-main",
               "credential_pool" => %{"strategy" => "round_robin", "entries" => entries}
             }
           } = provider_json(conn)

    assert length(entries) == 2

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :delete,
        ~p"/api/v2/site/ai-gateway/providers/chatgpt-main/credentials/enterprise-2"
      )

    assert %{"ai_gateway_provider" => %{"credential_pool" => %{"entries" => [remaining]}}} =
             provider_json(conn)

    assert remaining["id"] == "enterprise-1"
  end

  test "admin adds, updates, disables, and enables a generic pool credential", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> put_provider("openrouter-pool-admin", %{
        "provider_kind" => "openrouter",
        "credential_pool" => %{"entries" => []}
      })

    assert %{"ai_gateway_provider" => %{"credential_pool" => %{"entries" => []}}} =
             provider_json(conn)

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :post,
        ~p"/api/v2/site/ai-gateway/providers/openrouter-pool-admin/credentials",
        %{
          "id" => "key-1",
          "label" => "Primary",
          "priority" => 2,
          "api_key" => "sk-original"
        }
      )

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
           } = provider_json(conn, 201)

    refute conn.resp_body =~ "sk-original"

    disabled_at = DateTime.utc_now(:second) |> DateTime.to_iso8601()

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :put,
        ~p"/api/v2/site/ai-gateway/providers/openrouter-pool-admin/credentials/key-1",
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
           } = provider_json(conn)

    refute conn.resp_body =~ "sk-original"

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :put,
        ~p"/api/v2/site/ai-gateway/providers/openrouter-pool-admin/credentials/key-1",
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
           } = provider_json(conn)

    assert {:ok, provider} = ProviderConfigs.fetch_provider("openrouter-pool-admin")
    assert {:ok, %{"api_key" => "sk-original"}} = ProviderConfigs.runtime_connection(provider)
  end

  test "credential metadata updates do not clear dead health", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> put_provider("openrouter-dead-update", %{
        "provider_kind" => "openrouter",
        "credential_pool" => %{
          "entries" => [
            %{"id" => "dead-key", "label" => "Original", "api_key" => "sk-original"}
          ]
        }
      })

    assert %{"ai_gateway_provider" => %{"provider_id" => "openrouter-dead-update"}} =
             provider_json(conn)

    assert {:ok, provider} = ProviderConfigs.fetch_provider("openrouter-dead-update")
    [dead_entry] = provider.credential_pool["entries"]
    :ok = CredentialPool.mark_dead(provider.id, dead_entry, %{"code" => "token_revoked"})

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :put,
        ~p"/api/v2/site/ai-gateway/providers/openrouter-dead-update/credentials/dead-key",
        %{"label" => "Renamed"}
      )

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [%{"label" => "Renamed", "status" => "dead"}]
               }
             }
           } = provider_json(conn)

    assert {:ok, _} =
             ProviderConfigs.update_credential("openrouter-dead-update", "dead-key", %{
               "reauth_required" => true
             })

    :ok = CredentialPool.record_usage(provider.id, "dead-key", %{"total_tokens" => 11})

    :ok =
      CredentialPool.observe_success(provider.id, dead_entry, [
        {"x-codex-primary-used-percent", "37"}
      ])

    persisted_dead = show_provider(conn, "openrouter-dead-update")

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [
                   %{
                     "label" => "Renamed",
                     "status" => "dead",
                     "reauth_required" => true,
                     "request_count" => 0,
                     "last_selected_at" => nil,
                     "usage" => %{"model" => %{"total_tokens" => 11}},
                     "rate_limits" => %{"x-codex-primary-used-percent" => "37"}
                   }
                 ]
               }
             }
           } = provider_json(persisted_dead)

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :put,
        ~p"/api/v2/site/ai-gateway/providers/openrouter-dead-update/credentials/dead-key",
        %{"api_key" => "sk-reauthenticated"}
      )

    assert %{
             "ai_gateway_provider" => %{
               "credential_pool" => %{"entries" => [%{"status" => "ok"}]}
             }
           } = provider_json(conn)

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
      |> console_conn()
      |> put_provider("chatgpt-device", %{
        "provider_kind" => "chatgpt_subscription",
        "connection_options" => %{"auth_issuer" => issuer}
      })

    assert %{"ai_gateway_provider" => %{"provider_id" => "chatgpt-device"}} =
             provider_json(conn)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:post, ~p"/api/v2/site/ai-gateway/providers/chatgpt-device/chatgpt-login", %{
        "id" => "device-credential",
        "label" => "Device account",
        "priority" => 3
      })

    assert %{
             "mode" => "device",
             "user_code" => "ABCD-EFGH",
             "interval" => 1,
             "login_context" => login_context
           } = json_response(conn, 201)

    conn =
      conn
      |> recycle_api()
      |> send_v2(
        :post,
        ~p"/api/v2/site/ai-gateway/providers/chatgpt-device/chatgpt-login/poll",
        %{
          "login_context" => login_context
        }
      )

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
           } = json_response(conn, 201)

    refute conn.resp_body =~ "access-secret"
    refute conn.resp_body =~ "refresh-secret"
    refute conn.resp_body =~ id_token

    assert_receive {:chatgpt_auth_request,
                    %{path: "api/accounts/deviceauth/usercode", body: user_code_body}}

    assert user_code_body == %{"client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"}

    assert_receive {:chatgpt_auth_request,
                    %{path: "api/accounts/deviceauth/token", body: poll_body}}

    assert poll_body == %{
             "device_auth_id" => "device-auth-1",
             "user_code" => "ABCD-EFGH"
           }

    assert_receive {:chatgpt_auth_request, %{path: "oauth/token", body: exchange_body}}

    assert exchange_body == %{
             "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
             "code" => "authorization-code",
             "code_verifier" => verifier,
             "grant_type" => "authorization_code",
             "redirect_uri" => "#{issuer}/deviceauth/callback"
           }
  end

  test "provider kinds expose usable form settings and keep JSON default values", %{conn: conn} do
    assert %{"provider_kinds" => kinds} =
             conn
             |> console_conn()
             |> send_v2(:get, "/api/v2/site/ai-gateway/provider-kinds")
             |> json_response(200)

    openrouter = Enum.find(kinds, &(&1["provider_kind"] == "openrouter"))
    assert is_binary(openrouter["label"]["default"])
    assert "llm" in openrouter["capabilities"]

    assert %{"scope" => "request", "type" => "select", "default" => nil, "options" => [_ | _]} =
             Enum.find(openrouter["settings"], &(&1["key"] == "reasoningEffort"))

    assert %{"encrypted" => true, "scope" => "credential", "default" => nil} =
             Enum.find(openrouter["settings"], &(&1["key"] == "api_key"))
  end

  test "browser-paste login rejects another attempt and stores only a completed credential", %{
    conn: conn
  } do
    id_token =
      jwt(%{
        "email" => "browser@example.test",
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => "browser-account"}
      })

    test_pid = self()

    issuer =
      start_upstream_server(fn request ->
        case request.path do
          "api/accounts/deviceauth/usercode" ->
            {:json, 404, %{}}

          "oauth/token" ->
            send(test_pid, {:browser_exchange, request.body})

            {:json, 200,
             %{
               "access_token" => "browser-access-secret",
               "refresh_token" => "browser-refresh-secret",
               "id_token" => id_token
             }}
        end
      end)

    conn =
      conn
      |> console_conn()
      |> put_provider("browser-login", %{
        "provider_kind" => "chatgpt_subscription",
        "connection_options" => %{"auth_issuer" => issuer}
      })

    assert %{"ai_gateway_provider" => %{}} = provider_json(conn)
    path = "/api/v2/site/ai-gateway/providers/browser-login/chatgpt-login"

    assert %{"errors" => [%{"code" => "missing", "detail" => "access_token is required"}]} =
             conn
             |> send_v2(
               :post,
               "/api/v2/site/ai-gateway/providers/browser-login/chatgpt-enterprise-credentials",
               %{"account_id" => "browser-account"}
             )
             |> json_response(422)

    assert %{"mode" => "browser_paste", "authorization_url" => url, "login_context" => context} =
             conn
             |> send_v2(:post, path, %{"id" => "browser-credential", "label" => "Browser account"})
             |> json_response(201)

    assert URI.decode_query(URI.parse(url).query)["state"] == context["state"]

    rejected =
      send_v2(conn, :post, path <> "/browser-callback", %{
        "login_context" => context,
        "callback_url" => "http://localhost:1455/auth/callback?code=browser-code&state=wrong"
      })

    assert %{"errors" => [%{"code" => "chatgpt_login_invalid", "detail" => detail}]} =
             json_response(rejected, 422)

    assert detail =~ "different sign-in attempt"

    assert {:ok, %{"credential_pool" => %{"entries" => []}}} =
             ProviderConfigs.get_provider("browser-login")

    callback =
      "http://localhost:1455/auth/callback?" <>
        URI.encode_query(%{"code" => "browser-code", "state" => context["state"]})

    complete =
      send_v2(conn, :post, path <> "/browser-callback", %{
        "login_context" => context,
        "callback_url" => callback
      })

    assert %{
             "status" => "complete",
             "ai_gateway_provider" => %{
               "credential_pool" => %{
                 "entries" => [%{"id" => "browser-credential", "email" => "browser@example.test"}]
               }
             }
           } = json_response(complete, 201)

    refute complete.resp_body =~ "browser-access-secret"
    refute complete.resp_body =~ "browser-refresh-secret"
    assert_receive {:browser_exchange, %{"code" => "browser-code", "code_verifier" => verifier}}
    assert verifier == context["code_verifier"]
  end

  # Provider records and credentials use the site JSON:API.
  defp put_provider(conn, provider_id, attributes) do
    conn
    |> json_api()
    |> patch(
      ~p"/api/v2/site/ai-gateway/providers/#{provider_id}",
      Jason.encode!(%{data: %{type: "ai_gateway_provider", attributes: attributes}})
    )
  end

  defp show_provider(conn, provider_id),
    do: conn |> json_api() |> get(~p"/api/v2/site/ai-gateway/providers/#{provider_id}")

  defp json_api(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end

  defp provider_json(conn, status \\ 200),
    do: %{"ai_gateway_provider" => json_response(conn, status)["data"]["attributes"]}

  defp jwt(claims) do
    payload = claims |> Ankole.JSON.encode!() |> Base.url_encode64(padding: false)
    "e30.#{payload}.signature"
  end

  defp send_v2(conn, method, path, params \\ %{}) do
    conn =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

    cond do
      method in [:get, :delete] ->
        Phoenix.ConnTest.dispatch(conn, AnkoleWeb.Endpoint, method, path, nil)

      String.contains?(path, "/model-profiles/") ->
        Phoenix.ConnTest.dispatch(
          conn,
          AnkoleWeb.Endpoint,
          method,
          path,
          Jason.encode!(%{data: %{attrs: params}})
        )

      String.contains?(path, "/credentials") or String.contains?(path, "/credential-pool/") ->
        attributes =
          if String.contains?(path, "/credential-pool/"), do: params, else: %{credential: params}

        Phoenix.ConnTest.dispatch(
          conn,
          AnkoleWeb.Endpoint,
          if(method == :put, do: :patch, else: method),
          path,
          Jason.encode!(%{data: %{type: "ai_gateway_provider", attributes: attributes}})
        )

      String.ends_with?(path, "/chatgpt-enterprise-credentials") ->
        Phoenix.ConnTest.dispatch(
          conn,
          AnkoleWeb.Endpoint,
          method,
          path,
          Jason.encode!(%{data: %{credential: params}})
        )

      true ->
        Phoenix.ConnTest.dispatch(
          conn,
          AnkoleWeb.Endpoint,
          method,
          path,
          Jason.encode!(%{data: params})
        )
    end
  end
end
