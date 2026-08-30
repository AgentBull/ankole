defmodule Ankole.AIGateway.ProviderRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.SignalsGateway.ActorRuntimeCase,
    only: [
      rpc_request: 4,
      rpc_response_payload!: 2,
      envelope_body_type: 1,
      envelope_body!: 2
    ]

  alias Ankole.RuntimeFabric.V1, as: FabricProto

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIGateway.CodexModels
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Crypto
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ProviderRuntime
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AppConfigure
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.ActorRuntime.RPCLane
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig
  alias Ankole.SignalsGateway.ActorRuntime.TurnPolicy
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.Repo

  test "provider kind projection uses provider_kind vocabulary" do
    kinds = ProviderConfigs.list_provider_kinds()
    provider_kinds = Enum.map(kinds, & &1["provider_kind"])

    # Gemini reaches the gateway through google_ai_studio_openai; a bare kind
    # would take a second, untested wire. Every other kind in the catalog is
    # exercised by the capability and settings assertions below.
    refute "gemini" in provider_kinds

    openrouter = Enum.find(kinds, &(&1["provider_kind"] == "openrouter"))
    openai = Enum.find(kinds, &(&1["provider_kind"] == "openai"))
    openai_compatible = Enum.find(kinds, &(&1["provider_kind"] == "openai_compatible"))

    chatgpt_subscription =
      Enum.find(kinds, &(&1["provider_kind"] == "chatgpt_subscription"))

    google_ai_studio = Enum.find(kinds, &(&1["provider_kind"] == "google_ai_studio_openai"))
    azure_openai = Enum.find(kinds, &(&1["provider_kind"] == "azure_openai"))
    parallel = Enum.find(kinds, &(&1["provider_kind"] == "parallel"))
    jina_search = Enum.find(kinds, &(&1["provider_kind"] == "jina_search"))
    jina_reader = Enum.find(kinds, &(&1["provider_kind"] == "jina_reader"))
    bright_data_serp = Enum.find(kinds, &(&1["provider_kind"] == "bright_data_serp"))
    agentbull_cloud = Enum.find(kinds, &(&1["provider_kind"] == "agentbull_cloud"))

    assert "llm" in openrouter["capabilities"]
    assert "embedding" in openrouter["capabilities"]
    assert "rerank" in openrouter["capabilities"]
    assert "embedding" in google_ai_studio["capabilities"]
    assert "web_search" in parallel["capabilities"]
    assert "web_fetch" in parallel["capabilities"]
    assert "web_search" in jina_search["capabilities"]
    assert "web_fetch" in jina_reader["capabilities"]
    assert "web_search" in bright_data_serp["capabilities"]
    assert "web_search" in agentbull_cloud["capabilities"]
    assert agentbull_cloud["default_base_url"] == "https://cloudapis.agentbull.com"

    agentbull_cloud_settings = Map.new(agentbull_cloud["settings"], &{&1["key"], &1})
    assert agentbull_cloud_settings["api_key"]["required"]

    for {provider, endpoint_default} <- [
          {openai, "responses"},
          {openai_compatible, "chat_completions"}
        ] do
      settings = Map.new(provider["settings"], &{&1["key"], &1})

      assert settings["endpoint_kind"]["type"] == "select"
      assert settings["endpoint_kind"]["options"] == ~w(responses chat_completions)
      assert settings["endpoint_kind"]["default"] == endpoint_default

      assert settings["upstream_transport"]["type"] == "select"
      assert settings["upstream_transport"]["options"] == ~w(sse websocket)
      assert settings["upstream_transport"]["default"] == "sse"
    end

    compatible_settings = Map.new(openai_compatible["settings"], &{&1["key"], &1})
    assert compatible_settings["supports_openai_tools"]["type"] == "boolean"
    assert compatible_settings["supports_openai_tools"]["scope"] == "connection"
    assert compatible_settings["supports_openai_tools"]["default"] == false
    refute compatible_settings["supports_openai_tools"]["advanced"]

    for provider <- [chatgpt_subscription, azure_openai, openai, openai_compatible] do
      service_tier = Map.new(provider["settings"], &{&1["key"], &1})["serviceTier"]

      assert service_tier["type"] == "string"
      assert service_tier["options"] == ~w(fast flex)
      assert is_nil(service_tier["default"])
    end

    assert "transport" in openrouter["connection_options"]
    assert "transport" in openai_compatible["connection_options"]

    for provider_kind <- ~w(openai openrouter google_ai_studio_openai azure_openai claude) do
      provider = Enum.find(kinds, &(&1["provider_kind"] == provider_kind))

      assert Enum.find(provider["capability_specs"], &(&1["kind"] == "llm"))[
               "supports_parallel_tool_calls"
             ]
    end

    refute Enum.find(openai_compatible["capability_specs"], &(&1["kind"] == "llm"))[
             "supports_parallel_tool_calls"
           ]

    assert is_nil(azure_openai["default_base_url"])

    assert Enum.all?(kinds, fn provider ->
             label = provider["label"]

             Map.has_key?(label, "default") and Map.has_key?(label, "zh-Hans-CN") and
               not Map.has_key?(label, "en") and not Map.has_key?(label, "zh")
           end)
  end

  test "provider kind rejects kebab-case ids" do
    changeset =
      Provider.changeset(%Provider{}, %{
        provider_id: "bad-provider-kind",
        provider_kind: "openai-compatible",
        base_url: "https://compatible.test/v1",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn
             {:provider_kind, {"has invalid format", _opts}} -> true
             _error -> false
           end)
  end

  test "provider CRUD encrypts declared options and validates connection options" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               },
               connection_options: %{
                 "headers" => %{"Authorization" => "Bearer provider-managed"}
               }
             })

    refute Map.has_key?(provider.connection_options, "api_key")
    [stored_credential] = provider.credential_pool["entries"]
    assert is_binary(stored_credential["encrypted_credential"])
    assert is_binary(stored_credential["health_revision"])
    refute stored_credential["encrypted_credential"] == "sk-test"
    assert {:ok, connection} = ProviderConfigs.runtime_connection(provider)
    refute Map.has_key?(connection, "transport")
    assert connection["api_key"] == "sk-test"
    assert connection["headers"] == %{"Authorization" => "Bearer provider-managed"}

    assert {:ok, projection} = ProviderConfigs.get_provider("openrouter-main")

    assert [%{"credential_present" => true, "status" => "ok"}] =
             projection["credential_pool"]["entries"]

    refute Map.has_key?(hd(projection["credential_pool"]["entries"]), "health_revision")

    refute Map.has_key?(projection["connection_options"], "api_key")
    refute inspect(projection) =~ "sk-test"

    assert {:ok, compatible_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-main",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.test/v1",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:ok, compatible_connection} = ProviderConfigs.runtime_connection(compatible_provider)
    refute Map.has_key?(compatible_connection, "transport")

    assert {:ok, overridden_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-http2",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               },
               connection_options: %{
                 "transport" => %{"http_versions" => ["h1"], "compression" => ["gzip"]}
               }
             })

    assert {:ok, overridden_connection} = ProviderConfigs.runtime_connection(overridden_provider)

    assert overridden_connection["transport"] == %{
             "http_versions" => ["h1"],
             "compression" => ["gzip"]
           }

    json_secret = %{"access_key" => "ak-test", "secret_key" => "sk-test"}

    assert {:ok, json_secret_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "json-secret-provider",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => json_secret}]
               }
             })

    assert {:ok, json_secret_connection} =
             ProviderConfigs.runtime_connection(json_secret_provider)

    assert json_secret_connection["api_key"] == json_secret

    assert {:ok, json_secret_projection} = ProviderConfigs.get_provider("json-secret-provider")

    assert [%{"credential_present" => true}] =
             json_secret_projection["credential_pool"]["entries"]

    refute inspect(json_secret_projection) =~ "ak-test"
    refute inspect(json_secret_projection) =~ "sk-test"
  end

  test "a provider with optional credentials gets one anonymous pool member" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-anonymous",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.example.test/v1"
             })

    assert [stored] = provider.credential_pool["entries"]
    assert stored["source"] == "provider_default"
    assert is_binary(stored["encrypted_credential"])

    assert {:ok, connection} = ProviderConfigs.runtime_connection(provider)
    assert connection["base_url"] == "https://compatible.example.test/v1"
    refute Map.has_key?(connection, "api_key")

    assert {:ok, projection} = ProviderConfigs.get_provider("compatible-anonymous")

    assert [%{"credential_present" => true, "status" => "ok"}] =
             projection["credential_pool"]["entries"]
  end

  test "credential writes validate required fields and select values before encryption" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-credential-validation",
               provider_kind: "chatgpt_subscription"
             })

    assert {:error, {:credential_options, {:required, "access_token"}}} =
             ProviderConfigs.add_credential("chatgpt-credential-validation", %{
               "id" => "missing-token",
               "auth_type" => "oauth"
             })

    assert {:error,
            {:credential_options,
             {:invalid_value, "auth_type", "cookie", ["oauth", "enterprise_access_token"]}}} =
             ProviderConfigs.add_credential("chatgpt-credential-validation", %{
               "id" => "invalid-auth-type",
               "access_token" => "secret",
               "auth_type" => "cookie"
             })

    assert {:error, {:credential_options, {:required, "account_id"}}} =
             ProviderConfigs.add_credential("chatgpt-credential-validation", %{
               "id" => "enterprise-without-account",
               "access_token" => "secret",
               "auth_type" => "enterprise_access_token"
             })

    assert {:error, {:credential_options, {:required, "refresh_token"}}} =
             ProviderConfigs.add_credential("chatgpt-credential-validation", %{
               "id" => "oauth-without-refresh",
               "access_token" => "secret",
               "account_id" => "account-1",
               "id_token" => "id-token",
               "auth_type" => "oauth"
             })

    assert {:error, {:credential_options, {:required, "id_token"}}} =
             ProviderConfigs.add_credential("chatgpt-credential-validation", %{
               "id" => "oauth-without-id-token",
               "access_token" => "secret",
               "account_id" => "account-1",
               "refresh_token" => "refresh-token",
               "auth_type" => "oauth"
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-credential-validation",
               provider_kind: "claude",
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "claude-valid",
                     "api_key" => "secret",
                     "auth_mode" => "auth_token"
                   }
                 ]
               }
             })

    assert {:error,
            {:credential_options,
             {:invalid_value, "auth_mode", "cookie", ["api_key", "auth_token", "oauth"]}}} =
             ProviderConfigs.update_credential(
               "claude-credential-validation",
               "claude-valid",
               %{"auth_mode" => "cookie"}
             )
  end

  test "metadata updates cannot clear a persisted reauthentication requirement" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-dead-credential",
               provider_kind: "claude",
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "dead-entry",
                     "api_key" => "stale-secret",
                     "auth_mode" => "oauth"
                   }
                 ]
               }
             })

    [entry] = provider.credential_pool["entries"]

    dead_entry =
      entry
      |> Map.put("reauth_required", true)
      |> Map.put("migration_error", "legacy_secret_invalid")

    provider =
      provider
      |> Provider.changeset(%{
        credential_pool: %{
          "strategy" => "fill_first",
          "entries" => [dead_entry]
        }
      })
      |> Repo.update!()

    assert {:ok, updated} =
             ProviderConfigs.update_credential(
               provider.provider_id,
               "dead-entry",
               %{"label" => "Renamed"}
             )

    assert [updated_entry] = updated.credential_pool["entries"]
    assert updated_entry["label"] == "Renamed"
    assert updated_entry["health_revision"] == entry["health_revision"]
    assert updated_entry["reauth_required"] == true
    assert updated_entry["migration_error"] == "legacy_secret_invalid"

    assert {:ok, %{"api_key" => "stale-secret", "auth_mode" => "oauth"}} =
             Crypto.unseal(
               updated_entry["encrypted_credential"],
               updated.id,
               "credential:dead-entry"
             )

    assert {:ok, projection} = ProviderConfigs.get_provider(provider.provider_id)

    assert [%{"status" => "dead", "reauth_required" => true}] =
             projection["credential_pool"]["entries"]
  end

  test "provider helper runtime context reuses the decrypted runtime connection" do
    http_client = fn request -> {:ok, request} end

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-helper-context",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-helper"}]
               },
               connection_options: %{
                 "headers" => %{"X-Route" => "helper"},
                 "transport" => %{"http_versions" => ["h1"]}
               }
             })

    assert {:ok, ctx} =
             ProviderRuntime.context(provider,
               capability: "embedding",
               timeout_ms: 2_500,
               http_client: http_client
             )

    assert ctx.provider_id == "openrouter-helper-context"
    assert ctx.provider_kind == "openrouter"
    assert ctx.capability == "embedding"
    assert ctx.connection["api_key"] == "sk-helper"
    assert ctx.settings[:api_key] == "sk-helper"
    assert ctx.settings[:headers] == %{"X-Route" => "helper"}
    assert ctx.settings[:transport] == %{"http_versions" => ["h1"]}
    assert ctx.timeout_ms == 2_500
    assert ctx.http_client == http_client
    refute Map.has_key?(ctx, :request)
    refute Map.has_key?(ctx, :model)
  end

  test "provider live_check performs a redacted operator-triggered provider call" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               },
               connection_options: %{
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["gzip"],
                   "proxy" => "http://proxy.test:8080"
                 }
               }
             })

    http_client = fn request ->
      assert request.url == "https://openrouter.ai/api/v1/models"
      assert {"authorization", "Bearer sk-test"} in request.headers

      assert request.transport == %{
               "http_versions" => ["h1"],
               "compression" => ["gzip"],
               "proxy" => "http://proxy.test:8080"
             }

      assert request.timeout_ms == 15_000
      {:ok, %{"status" => 200, "body" => %{"data" => []}}}
    end

    assert {:ok, result} =
             ProviderRuntime.live_check_provider("openrouter-main", http_client: http_client)

    assert result["provider_id"] == "openrouter-main"
    assert result["provider_kind"] == "openrouter"
    assert result["status"] == "ok"
    refute inspect(result) =~ "sk-test"
  end

  test "provider live_check uses provider-owned auth header rules" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-oauth",
               provider_kind: "claude",
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "Default",
                     "api_key" => "anthropic-token",
                     "auth_mode" => "auth_token"
                   }
                 ]
               }
             })

    http_client = fn request ->
      assert request.url == "https://api.anthropic.com/v1/models"
      assert {"authorization", "Bearer anthropic-token"} in request.headers
      refute {"x-api-key", "anthropic-token"} in request.headers
      assert {"anthropic-version", "2023-06-01"} in request.headers
      {:ok, %{"status" => 200, "body" => %{"data" => []}}}
    end

    assert {:ok, %{"provider_kind" => "claude", "status" => "ok"}} =
             ProviderRuntime.live_check_provider("claude-oauth", http_client: http_client)
  end

  test "ChatGPT live_check preserves account, identity, and FedRAMP headers" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-fedramp-live",
               provider_kind: "chatgpt_subscription",
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "FedRAMP",
                     "access_token" => "chatgpt-access",
                     "refresh_token" => "chatgpt-refresh",
                     "id_token" => "chatgpt-id",
                     "account_id" => "account-fedramp",
                     "auth_type" => "oauth",
                     "fedramp" => true
                   }
                 ]
               }
             })

    http_client = fn request ->
      assert request.url ==
               "https://chatgpt.com/backend-api/codex/models?client_version=0.150.1"

      assert {"Authorization", "Bearer chatgpt-access"} in request.headers
      assert {"ChatGPT-Account-ID", "account-fedramp"} in request.headers
      assert {"Originator", "codex_cli_rs"} in request.headers
      assert {"X-OpenAI-Fedramp", "true"} in request.headers
      {:ok, %{"status" => 200, "body" => %{"models" => []}}}
    end

    assert {:ok, %{"provider_kind" => "chatgpt_subscription", "status" => "ok"}} =
             ProviderRuntime.live_check_provider("chatgpt-fedramp-live",
               http_client: http_client
             )
  end

  test "provider live_check uses Azure OpenAI catalog path and auth scheme" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-live",
               provider_kind: "azure_openai",
               base_url: "https://ankole-test.openai.azure.com",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "azure-key"}]
               },
               connection_options: %{
                 "api_version" => "2025-04-01-preview"
               }
             })

    http_client = fn request ->
      assert request.url ==
               "https://ankole-test.openai.azure.com/openai/models?api-version=2025-04-01-preview"

      assert {"api-key", "azure-key"} in request.headers
      refute {"authorization", "Bearer azure-key"} in request.headers
      {:ok, %{"status" => 200, "body" => %{"data" => []}}}
    end

    assert {:ok, %{"provider_kind" => "azure_openai", "status" => "ok"}} =
             ProviderRuntime.live_check_provider("azure-live", http_client: http_client)
  end

  test "provider live_check leaves missing encrypted options to provider-owned request logic" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-no-key",
               provider_kind: "openrouter",
               connection_options: %{}
             })

    http_client = fn request ->
      assert request.url == "https://openrouter.ai/api/v1/models"

      refute Enum.any?(request.headers, fn {name, _value} ->
               String.downcase(name) == "authorization"
             end)

      {:ok, %{"status" => 401, "body" => %{"error" => "missing key"}}}
    end

    assert {:error,
            {:provider_live_check_failed,
             %{
               "body" => "%{\"error\" => \"missing key\"}",
               "http_status" => 401,
               "reason" => "upstream_error"
             }}} =
             ProviderRuntime.live_check_provider("openrouter-no-key", http_client: http_client)
  end

  test "model profiles validate provider references and embedding/rerank capabilities" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-main",
               provider_kind: "claude",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-ant"}]}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-main",
               provider_kind: "jina",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "jina-key"}]}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-main",
               provider_kind: "parallel",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "parallel-key"}]
               }
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-search-main",
               provider_kind: "jina_search",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "jina-search-key"}]
               }
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-reader-main",
               provider_kind: "jina_reader",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "jina-reader-key"}]
               }
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-vision",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, %{profile: profile}} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               context_length: 1_048_576,
               provider_options: %{"reasoningEffort" => "medium"}
             })

    assert profile["provider_id"] == "openrouter-main"
    assert profile["context_length"] == 1_048_576
    assert profile["provider_options"] == %{"reasoningEffort" => "medium"}

    assert {:ok, primary_runtime_profile} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "primary")

    assert primary_runtime_profile["context_length"] == 1_048_576

    assert {:ok, %{profile: heavy_profile}} =
             ModelProfiles.put_model_profile(agent.uid, "heavy", %{
               provider_id: "openrouter-main",
               model: "anthropic/claude-sonnet-4.5"
             })

    assert heavy_profile["provider_id"] == "openrouter-main"

    assert {:ok, coding_profile} = ModelProfiles.get_model_profile(agent.uid, "coding")
    assert coding_profile["profile"] == "coding"
    assert coding_profile["fallback_profile"] == "heavy"
    assert coding_profile["model"] == "anthropic/claude-sonnet-4.5"

    assert {:ok, coding_runtime_profile} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "coding")

    assert coding_runtime_profile["profile"] == "coding"
    assert coding_runtime_profile["provider_id"] == "openrouter-main"
    assert coding_runtime_profile["model"] == "anthropic/claude-sonnet-4.5"

    assert {:error, {:provider_kind_missing_capability, "web_search"}} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "claude-main",
               model: "default"
             })

    assert {:ok, %{profile: web_search_profile}} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: "jina-search-main",
               model: "default"
             })

    assert web_search_profile["provider_id"] == "jina-search-main"

    assert {:ok, web_search_runtime_profile} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "web_search")

    assert web_search_runtime_profile["capability"] == "web_search"
    assert web_search_runtime_profile["provider_kind"] == "jina_search"

    assert {:ok, %{profile: web_fetch_profile}} =
             ModelProfiles.put_model_profile(agent.uid, "web_fetch", %{
               provider_id: "jina-reader-main",
               model: "default"
             })

    assert web_fetch_profile["provider_id"] == "jina-reader-main"

    assert {:ok, web_fetch_runtime_profile} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "web_fetch")

    assert web_fetch_runtime_profile["capability"] == "web_fetch"

    assert {:ok, %{profile: vision_fallback_profile}} =
             ModelProfiles.put_model_profile(agent.uid, "vision_fallback", %{
               provider_id: "openai-vision",
               model: "gpt-5"
             })

    assert vision_fallback_profile["provider_id"] == "openai-vision"

    assert {:ok, vision_runtime_profile} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "vision_fallback")

    assert vision_runtime_profile["capability"] == "llm"

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_model_profile(agent.uid, "vision_fallback", nil)

    assert {:error, :model_profile_not_configured} =
             ModelProfiles.get_model_profile(agent.uid, "vision_fallback")
  end

  test "custom model profiles require immutable LLM names and descriptions and remain deletable" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-custom-profile",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    assert ModelProfiles.custom_profile_name?("kimi")
    refute ModelProfiles.custom_profile_name?("primary")
    refute ModelProfiles.custom_profile_name?("Kimi")
    assert ModelProfiles.custom_profile_name?("embedding")
    assert ModelProfiles.custom_profile_name?("rerank")
    assert {:ok, "llm"} = ModelProfiles.profile_capability("kimi")
    assert {:ok, "llm"} = ModelProfiles.profile_capability("embedding")

    assert {:error, {:missing, "description"}} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", %{
               provider_id: provider.provider_id,
               model: "moonshotai/kimi-k2.7-code"
             })

    assert {:error, :invalid_model_profile} =
             ModelProfiles.put_model_profile(agent.uid, "Kimi", %{
               description: "Invalid uppercase name",
               provider_id: provider.provider_id,
               model: "moonshotai/kimi-k2.7-code"
             })

    assert {:error, :fixed_model_profile_description_not_allowed} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               description: "Fixed profiles do not have descriptions",
               provider_id: provider.provider_id,
               model: "openai/gpt-5.4"
             })

    assert {:error, {:custom_model_profile_description_too_long, 200}} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", %{
               description: String.duplicate("a", 201),
               provider_id: provider.provider_id,
               model: "moonshotai/kimi-k2.7-code"
             })

    assert {:ok, %{profile: stored}} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", %{
               description: "Long-context coding",
               provider_id: provider.provider_id,
               model: "moonshotai/kimi-k2.7-code",
               context_length: 262_144,
               provider_options: %{"reasoningEffort" => "high"}
             })

    assert stored["description"] == "Long-context coding"
    assert stored["context_length"] == 262_144

    assert {:ok, [%{"name" => "kimi", "description" => "Long-context coding"}]} =
             ModelProfiles.list_custom_model_profiles(agent.uid)

    assert {:ok, custom} = ModelProfiles.get_custom_model_profile(agent.uid, "kimi")
    assert custom["profile"] == "kimi"

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "kimi"
             })

    assert runtime["model"] == "moonshotai/kimi-k2.7-code"
    assert runtime["profile"] == "kimi"

    assert {:ok, turn_start_spec} =
             TurnPolicy.build_turn_start_spec(
               %{agent_uid: agent.uid, session_id: "session-custom-profile"},
               profile: "kimi"
             )

    assert turn_start_spec.request_context["custom_model_profiles"] == [
             %{"name" => "kimi", "description" => "Long-context coding"}
           ]

    assert {:error, :model_profile_not_configured} =
             Ankole.AIGateway.Resolver.resolve_request_model(other_agent.uid, "llm", %{
               "model" => "kimi"
             })

    provider
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    assert {:error, :provider_disabled} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "kimi")

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", nil)

    assert {:error, :model_profile_not_configured} =
             ModelProfiles.get_custom_model_profile(agent.uid, "kimi")

    assert {:ok, []} = ModelProfiles.list_custom_model_profiles(agent.uid)
  end

  test "turn start specs include input modalities and optional vision fallback refs" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-main",
               provider_kind: "openai",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-main"}]}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-vision",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-vision"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-main",
               model: "text-only-local"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "vision_fallback", %{
               provider_id: "openai-vision",
               model: "gpt-5"
             })

    assert {:ok, turn_start_spec} =
             TurnPolicy.build_turn_start_spec(%{
               agent_uid: agent.uid,
               session_id: "session-vision"
             })

    assert turn_start_spec.model_ref["input_modalities"] == ["text"]

    assert %{
             "profile" => "vision_fallback",
             "provider_id" => "openai-vision",
             "provider_kind" => "openai",
             "model" => "gpt-5",
             "input_modalities" => input_modalities
           } = turn_start_spec.model_ref["vision_fallback_model_ref"]

    assert "image" in input_modalities

    assert {:ok, %{"models" => manifest_models}} = CodexModels.manifest(agent.uid, "agent")

    assert Enum.find(manifest_models, &(&1["slug"] == "text-only-local"))["input_modalities"] == [
             "text",
             "image"
           ]

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_model_profile(agent.uid, "vision_fallback", nil)

    assert {:ok, %{"models" => manifest_models}} = CodexModels.manifest(agent.uid, "agent")

    assert Enum.find(manifest_models, &(&1["slug"] == "text-only-local"))["input_modalities"] == [
             "text"
           ]
  end

  test "turn start specs declare image generation when the primary or fallback route supports it" do
    %{principal: agent} = agent_fixture()

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-turn-hosted-tools",
               provider_kind: "openrouter",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-turn-hosted-tools",
               model: "openai/gpt-4o-mini"
             })

    :ok =
      ModelMetadataCache.put(
        {:image_model_catalog, "openrouter-turn-hosted-tools", provider.updated_at,
         "images/models"},
        [%{"id" => "openai/gpt-image-1"}],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, "openrouter-turn-hosted-tools", provider.updated_at,
         "images/models/openai/gpt-image-1/endpoints"},
        [
          %{
            "provider_slug" => "openai",
            "provider_tag" => "openai/gpt-image-1:openai",
            "supported_parameters" => %{}
          }
        ],
        60_000
      )

    actor_key = %{agent_uid: agent.uid, session_id: "session-turn-hosted-tools"}

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: "openrouter-turn-hosted-tools",
               model: "openai/gpt-image-1"
             })

    # This Agent's model provider cannot generate images. While the capability is
    # left to that provider, the Agent simply has none: the configured profile is
    # not a silent substitute.
    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)

    assert {:ok, _capabilities} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{
               "image_generate" => false
             })

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    assert turn_start_spec.hosted_tools == [%{"type" => "image_generation"}]

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", nil)

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-turn-native-image",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-turn-native-image",
               model: "gpt-5"
             })

    # Back to the default: this Agent leaves both capabilities to its model
    # provider, and OpenAI runs both inside its own turn.
    assert {:ok, _capabilities} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{"image_generate" => true})

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)

    assert turn_start_spec.hosted_tools == [
             %{"type" => "image_generation"},
             %{"type" => "web_search"}
           ]
  end

  test "turn start specs declare hosted web search for a Responses endpoint the Agent leaves to it" do
    %{principal: agent} = agent_fixture()

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compat-hosted-search",
               provider_kind: "openai_compatible",
               base_url: "https://compat.example.test/v1",
               connection_options: %{"endpoint_kind" => "responses"},
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "compat-hosted-search",
               model: "sonar-live"
             })

    actor_key = %{agent_uid: agent.uid, session_id: "session-hosted-web-search"}

    # Hosted web search rides the Responses wire, so declaring that endpoint kind
    # is the capability statement. New Agents leave the capability to it.
    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    assert turn_start_spec.hosted_tools == [%{"type" => "web_search"}]

    # The Agent can take the capability back for its own search provider.
    assert {:ok, _capabilities} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{"web_search" => false})

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)

    assert {:ok, _capabilities} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{"web_search" => true})

    # A Chat Completions endpoint cannot serve hosted tools, so this Agent has no
    # web search at all rather than a silent fallback to a search provider.
    assert {:ok, _provider} =
             ProviderConfigs.update_provider(provider.provider_id, %{
               "connection_options" => %{"endpoint_kind" => "chat_completions"}
             })

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)
  end

  test "turn start specs include scoped agent runtime policy without creating a default output cap" do
    %{principal: agent} = agent_fixture()
    max_output_tokens_definition = AgentConfig.max_output_tokens_definition()
    inactivity_timeout_definition = AgentConfig.inactivity_timeout_ms_definition()
    max_iterations_definition = AgentConfig.max_iterations_definition()
    assert :ok = AppConfigure.delete_global(max_output_tokens_definition)
    assert :ok = AppConfigure.delete_global(inactivity_timeout_definition)
    assert :ok = AppConfigure.delete_global(max_iterations_definition)
    assert :ok = AppConfigure.delete_for_agent(agent.uid, max_output_tokens_definition)
    assert :ok = AppConfigure.delete_for_agent(agent.uid, inactivity_timeout_definition)
    assert :ok = AppConfigure.delete_for_agent(agent.uid, max_iterations_definition)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-agent-policy",
               provider_kind: "openai",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-main"}]}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-agent-policy",
               model: "gpt-4o-mini"
             })

    actor_key = %{agent_uid: agent.uid, session_id: "session-agent-policy"}

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)

    assert turn_start_spec.model_ref["max_completion_tokens"] == 16_384
    assert get_in(turn_start_spec.request_context, ["ai_agent", "max_output_tokens"]) == nil

    assert get_in(turn_start_spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) ==
             AgentConfig.default_inactivity_timeout_ms()

    assert get_in(turn_start_spec.request_context, ["ai_agent", "max_iterations"]) == 90

    assert {:ok, 20_000} = AppConfigure.put_global(max_output_tokens_definition, 20_000)
    assert {:ok, 120_000} = AppConfigure.put_global(inactivity_timeout_definition, 120_000)
    assert {:ok, 120} = AppConfigure.put_global(max_iterations_definition, 120)

    assert {:ok, global_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    assert get_in(global_spec.request_context, ["ai_agent", "max_output_tokens"]) == 16_384
    assert get_in(global_spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) == 120_000
    assert get_in(global_spec.request_context, ["ai_agent", "max_iterations"]) == 120

    assert {:ok, 12_000} =
             AppConfigure.put_for_agent(agent.uid, max_output_tokens_definition, 12_000)

    assert {:ok, 0} = AppConfigure.put_for_agent(agent.uid, inactivity_timeout_definition, 0)

    assert {:ok, 7} =
             AppConfigure.put_for_agent(agent.uid, max_iterations_definition, 7)

    assert {:ok, agent_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    assert get_in(agent_spec.request_context, ["ai_agent", "max_output_tokens"]) == 12_000
    assert get_in(agent_spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) == 0
    assert get_in(agent_spec.request_context, ["ai_agent", "max_iterations"]) == 7
  end

  test "model profiles validate source-specific provider options and provider delete guard lists references" do
    %{principal: agent} = agent_fixture()
    %{principal: malformed_agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:error, {:provider_options, {:unknown_keys, ["thinking"]}}} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{"thinking" => %{"type" => "enabled"}}
             })

    assert {:error, {:provider_options, {:unknown_keys, ["reasoning"]}}} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{"reasoning" => %{"effort" => "medium"}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{"reasoningEffort" => "medium"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{"reasoningEffort" => "max"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2"
             })

    malformed_agent
    |> then(&Repo.get!(Ankole.Principals.Agent, &1.uid))
    |> Ankole.Principals.Agent.changeset(%{
      options: %{"ai_agent" => %{"models" => [%{"provider_id" => "openrouter-main"}]}}
    })
    |> Repo.update!()

    assert {:error, {:provider_in_use, references}} =
             ProviderConfigs.delete_provider("openrouter-main")

    assert references == Enum.sort(["#{agent.uid}:primary", "#{agent.uid}:light"])
  end

  test "disable then enable restores a provider without losing its pool" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "enable-cycle",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [
                   %{"id" => "cycle-key", "label" => "Default", "api_key" => "sk-test"}
                 ]
               }
             })

    [old_entry] = provider.credential_pool["entries"]
    :ok = CredentialPool.mark_dead(provider.id, old_entry)
    assert {:ok, disabled} = ProviderConfigs.delete_provider("enable-cycle")
    assert %DateTime{} = disabled.disabled_at

    assert {:ok, enabled} = ProviderConfigs.enable_provider("enable-cycle")
    assert enabled.disabled_at == nil
    assert [entry] = enabled.credential_pool["entries"]
    assert is_binary(entry["encrypted_credential"])
    refute entry["health_revision"] == old_entry["health_revision"]

    :ok = CredentialPool.mark_dead(provider.id, old_entry, %{"code" => "late_old_failure"})
    assert {:ok, projection} = ProviderConfigs.get_provider("enable-cycle")
    assert [%{"status" => "ok"}] = projection["credential_pool"]["entries"]

    assert {:error, :not_found} = ProviderConfigs.enable_provider("missing-provider")

    # A provider whose kind stopped existing while it was disabled must not
    # return to service: every request it received would fail to resolve.
    Repo.get_by!(Provider, provider_id: "enable-cycle")
    |> Ecto.Changeset.change(
      provider_kind: "retired_kind",
      disabled_at: DateTime.utc_now(:microsecond)
    )
    |> Repo.update!()

    assert {:error, :unknown_ai_gateway_provider} =
             ProviderConfigs.enable_provider("enable-cycle")
  end

  test "enabling an active provider preserves current credential health" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "active-enable-health",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [
                   %{"id" => "dead-key", "label" => "Dead", "api_key" => "sk-dead"},
                   %{"id" => "cooldown-key", "label" => "Cooldown", "api_key" => "sk-cooldown"}
                 ]
               }
             })

    dead_entry = Enum.find(provider.credential_pool["entries"], &(&1["id"] == "dead-key"))
    cooldown_entry = Enum.find(provider.credential_pool["entries"], &(&1["id"] == "cooldown-key"))

    :ok = CredentialPool.mark_dead(provider.id, dead_entry, %{"code" => "token_revoked"})

    :ok =
      CredentialPool.mark_exhausted(
        provider.id,
        cooldown_entry,
        429,
        %{
          "x-codex-primary-reset-at" =>
            DateTime.utc_now(:second) |> DateTime.add(600) |> DateTime.to_unix()
        }
      )

    assert {:ok, %Provider{disabled_at: nil}} =
             ProviderConfigs.enable_provider("active-enable-health")

    assert {:ok, projection} = ProviderConfigs.get_provider("active-enable-health")

    assert %{"cooldown-key" => "exhausted", "dead-key" => "dead"} ==
             Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1["status"]})
  end

  test "credential replacement isolates the new credential from late old failures" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "replacement-failure-order",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [
                   %{"id" => "replacement-key", "label" => "Default", "api_key" => "sk-old"}
                 ]
               }
             })

    [old_entry] = provider.credential_pool["entries"]
    :ok = CredentialPool.mark_dead(provider.id, old_entry, %{"code" => "old_failure"})

    assert {:error, {:credential_pool_exhausted, _details}} =
             ProviderConfigs.resolve_credential(provider)

    assert {:ok, updated} =
             ProviderConfigs.update_provider("replacement-failure-order", %{
               "credential_pool" => %{
                 "entries" => [
                   %{
                     "id" => "replacement-key",
                     "label" => "Default",
                     "api_key" => "sk-new"
                   }
                 ]
               }
             })

    [new_entry] = updated.credential_pool["entries"]
    refute new_entry["health_revision"] == old_entry["health_revision"]

    :ok =
      CredentialPool.mark_dead(provider.id, old_entry, %{"code" => "late_old_failure"})

    assert {:ok, projection} = ProviderConfigs.get_provider("replacement-failure-order")
    assert [%{"status" => "ok"}] = projection["credential_pool"]["entries"]

    assert {:ok, current_selection} = ProviderConfigs.resolve_credential(updated)
    assert current_selection["credential"]["api_key"] == "sk-new"

    :ok = CredentialPool.mark_dead(provider.id, new_entry, %{"code" => "new_failure"})

    assert {:ok, projection} = ProviderConfigs.get_provider("replacement-failure-order")
    assert [%{"status" => "dead"}] = projection["credential_pool"]["entries"]
  end

  test "runtime RPCLane resolves agent conversation context and DB-backed skill overlays" do
    %{principal: agent} = agent_fixture()
    assert {:ok, _defaults} = Ankole.AIAgent.Library.AgentPlugins.Config.defaults()
    assert {:ok, _sync} = Library.sync_agent_skills(agent.uid)

    assert {:ok, documents} = Library.list_agent_documents(agent.uid)

    assert {:ok, _mission} =
             Library.replace_agent_document(
               agent.uid,
               "mission",
               "Own the next-turn research workflow.",
               documents["mission"]["content_hash"]
             )

    assert {:ok, _soul} =
             Library.replace_agent_document(
               agent.uid,
               "soul",
               "Be exact, calm, and evidence-led.",
               documents["soul"]["content_hash"]
             )

    assert {:ok, _design} =
             Library.replace_agent_document(
               agent.uid,
               "design",
               "Use cobalt accents and generous whitespace.",
               documents["design"]["content_hash"]
             )

    channel_id = "lark:context"
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%Channel{
      id: channel_id,
      kind: :im_group,
      reply_mode: :entry,
      name: "策略讨论",
      metadata: %{"domain" => "feishu"},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })

    {route, turn} = assign_worker_route(agent.uid, "signal-channel:#{channel_id}")

    Conversation
    |> Repo.get_by!(subject_uid: agent.uid, conversation_key: "signal-channel:#{channel_id}")
    |> Conversation.changeset(%{
      metadata: %{
        "origin" => %{
          "channel_id" => channel_id,
          "channel_kind" => "im_group"
        }
      }
    })
    |> Repo.update!()

    mixed_case_turn = %{turn | actor: %{turn.actor | agent_uid: " #{String.upcase(agent.uid)} "}}

    assert {:ok, context_envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "turn-context-1",
                 "agent_conversation.context.resolve",
                 %FabricProto.AgentConversationContextRequest{},
                 turn: mixed_case_turn
               ),
               route
             )

    assert envelope_body_type(context_envelope) == :rpc_response,
           inspect(context_envelope)

    context_payload =
      rpc_response_payload!(context_envelope, FabricProto.AgentConversationContextResponse)

    assert context_payload.agent.display_name == agent.display_name
    assert context_payload.agent.role == "Research Analyst"
    assert context_payload.conversation.key == "signal-channel:#{channel_id}"
    assert context_payload.conversation.origin_channel.adapter == "lark"
    assert context_payload.conversation.origin_channel.kind == "im_group"
    assert context_payload.conversation.origin_channel.label == "策略讨论"
    assert context_payload.mission == "Own the next-turn research workflow."
    assert context_payload.soul == "Be exact, calm, and evidence-led."
    assert context_payload.design == "Use cobalt accents and generous whitespace."

    assert {:ok, current_documents} = Library.list_agent_documents(agent.uid)

    assert context_payload.mission_content_hash ==
             current_documents["mission"]["content_hash"]

    assert context_payload.soul_content_hash == current_documents["soul"]["content_hash"]
    assert context_payload.design_content_hash == current_documents["design"]["content_hash"]
    assert Enum.any?(context_payload.skills, &(&1.skill_name == "pdf"))

    research_plugin = Enum.find(context_payload.agent_plugins, &(&1.id == "deep-research"))
    assert Enum.any?(research_plugin.skills, &(&1.catalog_name == "create-deep-research"))

    assert {:ok, _lesson} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Prefer page-by-page verification.",
               agent.uid
             )

    assert {:ok, resolve_envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "skill-overlay-resolve-1",
                 "skills.overlay.resolve",
                 %FabricProto.SkillOverlayResolveRequest{skill_names: ["pdf", "xlsx"]},
                 turn: mixed_case_turn
               ),
               route
             )

    resolve_payload =
      rpc_response_payload!(resolve_envelope, FabricProto.SkillOverlayResolveResponse)

    assert Enum.map(resolve_payload.overlays, & &1.skill_name) == ["pdf", "xlsx"]

    pdf_overlay = hd(resolve_payload.overlays)
    assert pdf_overlay.has_overlay
    rendered_lessons = pdf_overlay.text
    assert rendered_lessons =~ "Field notes (dated; verify against the current environment):"
    assert rendered_lessons =~ ", human] Prefer page-by-page verification."
    refute List.last(resolve_payload.overlays).has_overlay
  end

  test "runtime RPCLane rejects agent conversation context requests from an unassigned worker route" do
    %{principal: target_agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()

    {_target_route, target_turn} =
      assign_worker_route(target_agent.uid, "signal-channel:target-context")

    {other_route, _other_turn} =
      assign_worker_route(other_agent.uid, "signal-channel:other-context")

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "turn-context-wrong-route",
                 "agent_conversation.context.resolve",
                 %FabricProto.AgentConversationContextRequest{},
                 turn: target_turn
               ),
               other_route
             )

    assert envelope_body_type(envelope) == :rpc_error
    assert envelope_body!(envelope, :rpc_error).code == "worker_not_assigned_to_turn"
  end

  test "runtime RPCLane accepts turn writes after active steer bumps revision" do
    %{principal: agent} = agent_fixture()
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:steered-write")

    turn.activation_uid
    |> then(&Repo.get_by!(ActorSessionActivation, activation_uid: &1))
    |> Ecto.Changeset.change(%{revision: 1})
    |> Repo.update!()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "brain-remember-after-steer",
                 "brain.remember",
                 %FabricProto.BrainRequest{
                   params_json:
                     Torque.encode!(%{
                       "claim" => "Steered turns can still write memory.",
                       "kind" => "fact",
                       "scope" => "world",
                       "provenance" => "provider runtime steer test"
                     })
                 },
                 turn: turn
               ),
               route
             )

    assert envelope_body_type(envelope) == :rpc_response, inspect(envelope)
  end

  test "worker auth key is global AppConfigure state" do
    definition = WorkerAuthKey.definition()

    assert :ok = AppConfigure.delete_global(definition)

    assert {:ok, first} = WorkerAuthKey.ensure()
    assert {:ok, same} = WorkerAuthKey.ensure()
    assert first == same
    assert first =~ ~r/\A[0-9a-f]{64}\z/

    assert {:error, {:global_scope_only, _key}} =
             AppConfigure.put_for_agent("agent-a", definition, "agent-specific")
  end

  defp assign_worker_route(agent_uid, session_id) do
    route = "route-#{System.unique_integer([:positive])}"
    worker_id = "worker-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      incarnation_id: Ecto.UUID.generate(),
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })

    Repo.insert!(%ActorSessionWorkerAssignment{
      agent_uid: agent_uid,
      session_id: session_id,
      worker_id: worker_id,
      transport_route: route,
      status: "assigned",
      assigned_at: now,
      metadata: %{}
    })

    conversation =
      Repo.insert!(%Conversation{
        id: Ecto.UUID.generate(),
        subject_uid: agent_uid,
        conversation_key: session_id,
        metadata: %{},
        inserted_at: now,
        updated_at: now
      })

    actor_event =
      Repo.insert!(
        ActorEvent.changeset(%ActorEvent{}, %{
          agent_uid: agent_uid,
          binding_name: "test",
          session_id: session_id,
          source_event_id: "test-turn-#{System.unique_integer([:positive])}",
          type: "test.turn",
          available_at: now,
          queue_sequence: 1,
          input_state: "open",
          payload: %{}
        })
      )

    Repo.insert!(%Message{
      subject_uid: agent_uid,
      conversation_id: conversation.id,
      type: "message",
      status: "generating",
      content: [],
      metadata: %{
        "actor_event_id" => actor_event.id,
        "profile" => "primary",
        "provider" => "test-provider",
        "model" => "z-ai/glm-5.2",
        "request_context" => %{},
        "request_refs" => [],
        "request_patches" => [],
        "response" => %{},
        "tool_results" => [],
        "usage" => %{},
        "provider_metadata" => %{},
        "started_at" => now
      },
      inserted_at: now,
      updated_at: now
    })

    activation_uid = "activation-#{System.unique_integer([:positive])}"

    Repo.insert!(%ActorSessionActivation{
      activation_uid: activation_uid,
      agent_uid: agent_uid,
      session_id: session_id,
      actor_epoch: 1,
      status: "active",
      controller_node: "test",
      lease_id: "lease-#{System.unique_integer([:positive])}",
      lease_expires_at: DateTime.add(now, 60, :second),
      assigned_worker_id: worker_id,
      current_actor_event_id: actor_event.id,
      revision: 0,
      started_at: now,
      metadata: %{},
      inserted_at: now,
      updated_at: now
    })

    {route,
     %FabricProto.ActorTurnRef{
       actor: %FabricProto.ActorKey{agent_uid: agent_uid, session_id: session_id},
       activation_uid: activation_uid,
       actor_epoch: 1,
       actor_event_id: actor_event.id,
       revision: 0
     }}
  end
end
