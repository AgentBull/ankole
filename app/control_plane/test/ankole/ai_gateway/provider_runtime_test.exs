defmodule Ankole.AIGateway.ProviderRuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase,
    only: [
      rpc_request: 4,
      handle_rpc: 3,
      rpc_response_payload!: 2,
      envelope_body_type: 1,
      envelope_body!: 2
    ]

  import Ankole.AIGatewayCase, only: [assign_worker_route: 2]

  alias Ankole.RuntimeFabric.V1, as: FabricProto

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIGateway.CodexModels
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderDefinition
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Crypto
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ProviderRuntime
  alias Ankole.AIGateway.Providers
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AppConfigure
  import Ankole.ExternalConversationsFixtures
  alias Ankole.Sessions.AgentConfig
  alias Ankole.Sessions.Context
  alias Ankole.AgentWorkers.WorkerAuthKey
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

    for kind <- ~w(openrouter openai_compatible) do
      assert {:ok, definition} = Providers.fetch(kind)
      assert "transport" in Providers.connection_option_keys(definition)
    end

    for kind <- ~w(openai openrouter google_ai_studio_openai azure_openai claude) do
      assert {:ok, definition} = Providers.fetch(kind)
      assert {:ok, capability} = ProviderDefinition.capability(definition, :language_model)
      assert capability.supports_parallel_tool_calls?
    end

    assert {:ok, definition} = Providers.fetch("openai_compatible")
    assert {:ok, capability} = ProviderDefinition.capability(definition, :language_model)
    refute capability.supports_parallel_tool_calls?

    assert is_nil(azure_openai["default_base_url"])

    assert Enum.all?(kinds, fn provider ->
             label = provider["label"]

             Map.has_key?(label, "default") and Map.has_key?(label, "zh-Hans-CN") and
               not Map.has_key?(label, "en") and not Map.has_key?(label, "zh")
           end)
  end

  test "provider kind rejects kebab-case ids" do
    assert {:ok, changeset} =
             Repo.transact(fn ->
               {:ok,
                Ankole.Ash.for_create(Provider, :create, %{
                  input: %{
                    provider_id: "bad-provider-kind",
                    provider_kind: "openai-compatible",
                    base_url: "https://compatible.test/v1",
                    credential_pool: %{
                      "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
                    }
                  }
                })}
             end)

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn
             %Ash.Error.Changes.InvalidAttribute{field: :provider_kind} -> true
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
                 "transport" => %{"proxy" => "http://proxy.test:8080"}
               }
             })

    assert {:ok, overridden_connection} = ProviderConfigs.runtime_connection(overridden_provider)

    assert overridden_connection["transport"] == %{"proxy" => "http://proxy.test:8080"}

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
      |> Ecto.Changeset.change(%{
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
                 "transport" => %{"proxy" => "http://proxy.test:8080"}
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
    assert ctx.settings[:transport] == %{"proxy" => "http://proxy.test:8080"}
    assert ctx.timeout_ms == 2_500
    assert ctx.http_client == http_client
    refute Map.has_key?(ctx, :request)
    refute Map.has_key?(ctx, :model)
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
             Context.runtime(
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
             Context.runtime(%{
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
    # The hosted brain declaration follows `brain.enabled`, not the provider.
    # The configuration cache outlives the sandbox transaction, so clear it.
    assert {:ok, _write} = AppConfigure.put_global_by_key("brain.enabled", false)
    on_exit(fn -> Ankole.AppConfigure.Cache.clear_for_test() end)

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

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: "openrouter-turn-hosted-tools",
               model: "openai/gpt-image-1"
             })

    # This Agent's model provider cannot generate images. While the capability is
    # left to that provider, the Agent simply has none: the configured profile is
    # not a silent substitute.
    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)

    assert {:ok, _capabilities} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{
               "image_generate" => false
             })

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
    assert turn_start_spec.hosted_tools == [%{"type" => "image_generation"}]

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", nil)

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
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

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)

    assert turn_start_spec.hosted_tools == [
             %{"type" => "image_generation"},
             %{"type" => "web_search"}
           ]
  end

  test "turn start specs declare hosted web search for a Responses endpoint the Agent leaves to it" do
    %{principal: agent} = agent_fixture()
    assert {:ok, _write} = AppConfigure.put_global_by_key("brain.enabled", false)
    on_exit(fn -> Ankole.AppConfigure.Cache.clear_for_test() end)

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
    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
    assert turn_start_spec.hosted_tools == [%{"type" => "web_search"}]

    # The Agent can take the capability back for its own search provider.
    assert {:ok, _capabilities} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{"web_search" => false})

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)

    assert {:ok, _capabilities} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{"web_search" => true})

    # A Chat Completions endpoint cannot serve hosted tools, so this Agent has no
    # web search at all rather than a silent fallback to a search provider.
    assert {:ok, _provider} =
             ProviderConfigs.update_provider(provider.provider_id, %{
               "connection_options" => %{"endpoint_kind" => "chat_completions"}
             })

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)
  end

  test "turn start specs declare the hosted brain tool while Brain is enabled" do
    Ankole.AppConfigure.Cache.clear_for_test()
    on_exit(fn -> Ankole.AppConfigure.Cache.clear_for_test() end)
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compat-brain-turn",
               provider_kind: "openai_compatible",
               base_url: "https://compat.example.test/v1",
               connection_options: %{"endpoint_kind" => "chat_completions"},
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "compat-brain-turn",
               model: "sonar-live"
             })

    actor_key = %{agent_uid: agent.uid, session_id: "session-hosted-brain"}

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
    assert turn_start_spec.hosted_tools == [%{"type" => "brain"}]

    assert {:ok, _write} = AppConfigure.put_global_by_key("brain.enabled", false)
    assert {:ok, turn_start_spec} = Context.runtime(actor_key)
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
    assert :ok = AppConfigure.delete_tenant_by_key(max_output_tokens_definition.key)
    assert :ok = AppConfigure.delete_tenant_by_key(inactivity_timeout_definition.key)
    assert :ok = AppConfigure.delete_tenant_by_key(max_iterations_definition.key)

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

    assert {:ok, turn_start_spec} = Context.runtime(actor_key)

    assert turn_start_spec.model_ref["max_completion_tokens"] == 16_384
    assert get_in(turn_start_spec.request_context, ["ai_agent", "max_output_tokens"]) == nil

    assert get_in(turn_start_spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) ==
             AgentConfig.default_inactivity_timeout_ms()

    assert get_in(turn_start_spec.request_context, ["ai_agent", "max_iterations"]) == 90

    assert {:ok, 20_000} = AppConfigure.put_global(max_output_tokens_definition, 20_000)
    assert {:ok, 120_000} = AppConfigure.put_global(inactivity_timeout_definition, 120_000)
    assert {:ok, 120} = AppConfigure.put_global(max_iterations_definition, 120)

    assert {:ok, global_spec} = Context.runtime(actor_key)
    assert get_in(global_spec.request_context, ["ai_agent", "max_output_tokens"]) == 16_384
    assert get_in(global_spec.request_context, ["ai_agent", "inactivity_timeout_ms"]) == 120_000
    assert get_in(global_spec.request_context, ["ai_agent", "max_iterations"]) == 120

    assert {:ok, 12_000} =
             AppConfigure.put_tenant_by_key(max_output_tokens_definition.key, 12_000)

    assert {:ok, 0} = AppConfigure.put_tenant_by_key(inactivity_timeout_definition.key, 0)

    assert {:ok, 7} =
             AppConfigure.put_tenant_by_key(max_iterations_definition.key, 7)

    assert {:ok, agent_spec} = Context.runtime(actor_key)
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

    assert {:error,
            {:provider_options, {:invalid_setting_type, "provider", :map, "example-host"}}} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{"provider" => "example-host"}
             })

    assert {:ok,
            %{profile: %{"provider_options" => %{"provider" => %{"ignore" => ["example-host"]}}}}} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2",
               provider_options: %{
                 "reasoningEffort" => "max",
                 "provider" => %{"ignore" => ["example-host"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2"
             })

    {:ok, _} =
      Repo.transact(fn ->
        Ankole.Ash.update(
          Repo.get!(Ankole.Principals.Agent, malformed_agent.uid),
          :options_in_tx,
          %{
            options: %{"ai_agent" => %{"models" => [%{"provider_id" => "openrouter-main"}]}}
          }
        )
      end)

    assert {:error, {:provider_in_use, references}} =
             ProviderConfigs.delete_provider("openrouter-main")

    assert references == Enum.sort(["#{agent.uid}:primary", "#{agent.uid}:light"])
  end

  test "stored Brain model settings prevent disabling their Provider" do
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: "brain-reference",
               provider_kind: "openrouter",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    for {key, extra} <- [
          {"brain.embedding_model", %{"dimensions" => 4096}},
          {"brain.rerank_model", %{}}
        ] do
      model = Map.merge(%{"provider_id" => "brain-reference", "model" => "model"}, extra)
      assert {:ok, _} = AppConfigure.put_global_by_key(key, model)

      assert {:error, {:provider_in_use, [^key]}} =
               ProviderConfigs.delete_provider("brain-reference")

      assert :ok = AppConfigure.delete_global_by_key(key)
    end

    assert {:ok, %{disabled_at: %DateTime{}}} = ProviderConfigs.delete_provider("brain-reference")
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
    %{principal: agent} = Ankole.AIGatewayCase.background_agent_fixture()
    {:ok, coding} = ModelProfiles.get_model_profile(agent.uid, "coding")
    :ok = Ankole.SessionsCase.cache_actor_runtime_models(coding["provider_id"])
    defaults_key = "ai_agent.library.skill_defaults"
    assert {:ok, _defaults} = Ankole.AIAgent.Library.AgentPlugins.Config.defaults()
    assert {:ok, _defaults} = AppConfigure.put_tenant_by_key(defaults_key, %{"ocr" => true})

    assert {:ok, %{skills: %{"ocr" => true}}} =
             Ankole.AIAgent.Library.AgentPlugins.Config.defaults()

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

    channel_id =
      external_conversation_fixture("lark:context", %{
        title: "策略讨论",
        metadata: %{"domain" => "feishu"}
      }).id

    {route, turn} = assign_worker_route(agent.uid, "conversation:#{channel_id}")

    Conversation
    |> Repo.get_by!(subject_uid: agent.uid, conversation_key: "conversation:#{channel_id}")
    |> Ecto.Changeset.change(%{
      metadata: %{
        "origin" => %{
          "conversation_id" => channel_id,
          "channel_kind" => "im_group"
        }
      }
    })
    |> Repo.update!()

    assert {:ok, %{job: job, dispatch_event: input}} =
             Ankole.BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => turn.session.session_id,
               "source_signal_id" => turn.signal_id,
               "source_tool_call_id" => "context-job-#{Ecto.UUID.generate()}",
               "title" => "Resolve Job context",
               "task" => "Read the owner conversation context.",
               "reply_route" => %{"binding_name" => "lark", "conversation_id" => channel_id}
             })

    assert {:ok, %{"skills" => cached_skills}} = Library.runtime_catalog_for_agent(agent.uid)
    assert Enum.any?(cached_skills, &(&1["skill_name"] == "ocr"))

    # A running attempt reads current rows even when the cache still holds
    # choices from before this transaction.
    {:ok, projection} =
      Repo.transact(fn ->
        assert {:ok, %{value: %{"value" => %{"ocr" => false}}}} =
                 Ankole.Ash.create(Ankole.AppConfigure.AppConfig, :put, %{
                   scope: "tenant:" <> Repo.tenant_id!(),
                   key: defaults_key,
                   input: %{"ocr" => false}
                 })

        assert {:ok, %{skills: %{"ocr" => true}}} =
                 Ankole.AIAgent.Library.AgentPlugins.Config.defaults()

        Ankole.BackgroundAgentJobs.RuntimeProjection.capture(agent.uid, %{
          model_ref: %{"provider_id" => "ai_gateway", "model" => "test"}
        })
      end)

    refute Enum.any?(projection["skills"], &(&1["name"] == "ocr"))

    job
    |> Ecto.Changeset.change(status: :running, attempts: 1, runtime_projection: projection)
    |> Repo.update!()

    job_turn = %FabricProto.JobTurnRef{
      signal_id: input.id,
      job_id: job.id,
      attempt: 1
    }

    assert {:ok, context} =
             Context.resolve(agent.uid, Ankole.BackgroundAgentJobs.job_session_id(job.id))

    assert {:ok, selected_context} =
             Context.job(context, Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, job.id))

    context_payload =
      Ankole.Sessions.TurnEnvelope.agent_context(selected_context)

    assert context.agent.display_name == agent.display_name
    assert context.agent.role == "Research Analyst"
    assert context.conversation.key == "conversation:#{channel_id}"
    assert context.conversation.origin_channel.adapter == "lark"
    assert context.conversation.origin_channel.kind == "im_group"
    assert context.conversation.origin_channel.label == "策略讨论"
    assert context_payload.conversation.timezone == context.conversation.timezone
    assert context_payload.mission == "Own the next-turn research workflow."
    assert context_payload.soul == "Be exact, calm, and evidence-led."
    assert context_payload.design == "Use cobalt accents and generous whitespace."

    assert {:ok, current_documents} = Library.list_agent_documents(agent.uid)

    assert context_payload.confidentiality_policy ==
             current_documents["confidentiality_policy"]["content"]

    assert Enum.any?(context_payload.skills, &(&1.skill_name == "pdf"))
    refute Enum.any?(context_payload.skills, &(&1.skill_name == "ocr"))

    research_plugin = Enum.find(context_payload.agent_plugins, &(&1.id == "deep-research"))
    assert Enum.any?(research_plugin.skills, &(&1.catalog_name == "create-deep-research"))

    assert {:ok, _lesson} =
             Library.create_skill_lesson(
               agent.uid,
               "pdf",
               "Prefer page-by-page verification.",
               Ankole.ActorRef.from_principal(agent)
             )

    assert {:ok, resolve_envelope} =
             handle_rpc(
               rpc_request(
                 "read-tool-1",
                 "tools.read",
                 %FabricProto.ReadToolRequest{
                   name: "skill_view",
                   arguments_json: Ankole.JSON.encode!(%{"name" => "pdf"})
                 },
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    response = rpc_response_payload!(resolve_envelope, FabricProto.JSONPassthroughResponse)
    result = Ankole.JSON.decode!(response.body_json)
    assert result["output"] =~ "Field notes (dated; verify against the current environment):"
    assert result["output"] =~ ", human] Prefer page-by-page verification."
    assert result["details"]["name"] == "pdf"
  end

  test "runtime RPCLane rejects Job reads from another Agent's Worker" do
    %{principal: target_agent} = Ankole.AIGatewayCase.background_agent_fixture()
    %{principal: other_agent} = agent_fixture()

    {target_route, target_turn} =
      assign_worker_route(target_agent.uid, "signal-channel:target-context")

    {other_route, _other_turn} =
      assign_worker_route(other_agent.uid, "signal-channel:other-context")

    assert {:ok, %{job: job, dispatch_event: input}} =
             Ankole.BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => target_agent.uid,
               "owner_session_id" => target_turn.session.session_id,
               "source_signal_id" => target_turn.signal_id,
               "source_tool_call_id" => "context-auth-#{Ecto.UUID.generate()}",
               "title" => "Authorize Job context",
               "task" => "Read the owner conversation context.",
               "reply_route" => %{"binding_name" => "test"}
             })

    # A running attempt has the projection its claim captured.
    {:ok, projection} =
      Ankole.BackgroundAgentJobs.RuntimeProjection.capture(target_agent.uid, %{
        model_ref: %{"provider_id" => "ai_gateway", "model" => "test"}
      })

    job
    |> Ecto.Changeset.change(status: :running, attempts: 1, runtime_projection: projection)
    |> Repo.update!()

    request =
      rpc_request(
        "turn-context-wrong-route",
        "background_agent_job.get",
        %FabricProto.BackgroundAgentJobGetRequest{job_id: Integer.to_string(job.id)},
        job_turn: %FabricProto.JobTurnRef{
          signal_id: input.id,
          job_id: job.id,
          attempt: 1
        }
      )

    assert {:ok, accepted} = handle_rpc(request, target_route, target_agent.uid)
    assert envelope_body_type(accepted) == :rpc_response

    assert {:ok, envelope} =
             handle_rpc(request, other_route, other_agent.uid)

    assert envelope_body_type(envelope) == :rpc_error
    assert envelope_body!(envelope, :rpc_error).code == "background_agent_job_attempt_changed"
  end

  test "worker auth key is global AppConfigure state" do
    agent_fixture()
    definition = WorkerAuthKey.definition()

    assert :ok = AppConfigure.delete_global(definition)

    assert {:ok, first} = WorkerAuthKey.ensure()
    assert {:ok, same} = WorkerAuthKey.ensure()
    assert first == same
    assert first =~ ~r/\A[0-9a-f]{64}\z/

    assert {:error, {:global_scope_only, _key}} =
             AppConfigure.put_tenant_by_key(definition.key, "agent-specific")
  end
end
