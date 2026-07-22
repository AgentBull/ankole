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
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ProviderRuntime
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AppConfigure
  alias Ankole.SignalsGateway.ActorEvent
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

    assert "openrouter" in provider_kinds
    assert "openai" in provider_kinds
    assert "openai_compatible" in provider_kinds
    assert "google_ai_studio_openai" in provider_kinds
    assert "jina" in provider_kinds
    assert "parallel" in provider_kinds
    assert "bright_data_serp" in provider_kinds
    assert "agentbull_cloud" in provider_kinds
    assert "jina_search" in provider_kinds
    assert "jina_reader" in provider_kinds
    assert "claude" in provider_kinds
    assert "azure_openai" in provider_kinds
    refute "gemini" in provider_kinds
    refute kinds |> List.first() |> Map.has_key?("provider_family")
    openrouter = Enum.find(kinds, &(&1["provider_kind"] == "openrouter"))
    openai_compatible = Enum.find(kinds, &(&1["provider_kind"] == "openai_compatible"))
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

    assert "transport" in openrouter["connection_options"]
    assert "transport" in openai_compatible["connection_options"]

    assert is_nil(azure_openai["default_base_url"])
    refute Map.has_key?(openrouter, "default_transport")
    refute Map.has_key?(azure_openai, "default_transport")

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
        connection_options: %{"api_key" => "sk-test"},
        encrypted_options: %{}
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
               connection_options: %{
                 "api_key" => "sk-test",
                 "headers" => %{"Authorization" => "Bearer provider-managed"}
               }
             })

    refute Map.has_key?(provider.connection_options, "api_key")
    assert is_binary(provider.encrypted_options["api_key"])
    refute provider.encrypted_options["api_key"] == "sk-test"
    assert {:ok, connection} = ProviderConfigs.runtime_connection(provider)
    refute Map.has_key?(connection, "transport")
    assert connection["api_key"] == "sk-test"
    assert connection["headers"] == %{"Authorization" => "Bearer provider-managed"}

    assert {:ok, projection} = ProviderConfigs.get_provider("openrouter-main")

    assert projection["encrypted_options"] == %{
             "api_key" => %{"present" => true, "masked" => "********"}
           }

    refute Map.has_key?(projection["connection_options"], "api_key")
    refute inspect(projection) =~ "sk-test"

    assert {:ok, compatible_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-main",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.test/v1",
               connection_options: %{"api_key" => "sk-test"}
             })

    assert {:ok, compatible_connection} = ProviderConfigs.runtime_connection(compatible_provider)
    refute Map.has_key?(compatible_connection, "transport")

    assert {:ok, overridden_provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-http2",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.test/v1",
               connection_options: %{
                 "api_key" => "sk-test",
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
               connection_options: %{"api_key" => json_secret}
             })

    assert {:ok, json_secret_connection} =
             ProviderConfigs.runtime_connection(json_secret_provider)

    assert json_secret_connection["api_key"] == json_secret

    assert {:ok, json_secret_projection} = ProviderConfigs.get_provider("json-secret-provider")

    assert json_secret_projection["encrypted_options"] == %{
             "api_key" => %{"present" => true, "masked" => "********"}
           }

    refute inspect(json_secret_projection) =~ "ak-test"
    refute inspect(json_secret_projection) =~ "sk-test"
  end

  test "provider helper runtime context reuses the decrypted runtime connection" do
    http_client = fn request -> {:ok, request} end

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-helper-context",
               provider_kind: "openrouter",
               connection_options: %{
                 "api_key" => "sk-helper",
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
               connection_options: %{
                 "api_key" => "sk-test",
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
               connection_options: %{"api_key" => "anthropic-token", "auth_mode" => "auth_token"}
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

  test "provider live_check uses Azure OpenAI catalog path and auth scheme" do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "azure-live",
               provider_kind: "azure_openai",
               base_url: "https://ankole-test.openai.azure.com",
               connection_options: %{
                 "api_key" => "azure-key",
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
               "http_status" => 401,
               "reason" => "upstream_error",
               "body" => "%{\"error\" => \"missing key\"}"
             }}} =
             ProviderRuntime.live_check_provider("openrouter-no-key", http_client: http_client)
  end

  test "model profiles validate provider references and embedding/rerank capabilities" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               connection_options: %{"api_key" => "sk-test"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-main",
               provider_kind: "claude",
               connection_options: %{"api_key" => "sk-ant"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-main",
               provider_kind: "jina",
               connection_options: %{"api_key" => "jina-key"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "parallel-main",
               provider_kind: "parallel",
               connection_options: %{"api_key" => "parallel-key"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-search-main",
               provider_kind: "jina_search",
               connection_options: %{"api_key" => "jina-search-key"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-reader-main",
               provider_kind: "jina_reader",
               connection_options: %{"api_key" => "jina-reader-key"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-vision",
               provider_kind: "openai",
               connection_options: %{"api_key" => "sk-openai"}
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

    assert {:error, {:provider_kind_missing_capability, "embedding"}} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: "claude-main",
               model: "claude-sonnet-4-5"
             })

    assert {:ok, %{profile: embedding_profile}} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: "jina-main",
               model: "jina-embeddings-v4"
             })

    assert embedding_profile["provider_id"] == "jina-main"

    assert {:ok, runtime_profile} =
             ModelProfiles.resolve_runtime_profile(agent.uid, "embedding")

    assert runtime_profile["capability"] == "embedding"

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

  test "turn start specs include input modalities and optional vision fallback refs" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-main",
               provider_kind: "openai",
               connection_options: %{"api_key" => "sk-main"}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-vision",
               provider_kind: "openai",
               connection_options: %{"api_key" => "sk-vision"}
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
  end

  test "turn start specs declare image generation only while the agent profile resolves" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-turn-hosted-tools",
               provider_kind: "openrouter",
               connection_options: %{"api_key" => "sk-test"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-turn-hosted-tools",
               model: "openai/gpt-4o-mini"
             })

    :ok =
      ModelMetadataCache.put(
        {:image_model_catalog, "openrouter-turn-hosted-tools", "images/models"},
        [%{"id" => "openai/gpt-image-1"}],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, "openrouter-turn-hosted-tools",
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

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    assert turn_start_spec.hosted_tools == [%{"type" => "image_generation"}]

    assert {:ok, %{profile: nil}} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", nil)

    assert {:ok, turn_start_spec} = TurnPolicy.build_turn_start_spec(actor_key)
    refute Map.has_key?(turn_start_spec, :hosted_tools)
  end

  test "turn start specs include scoped agent runtime policy without creating a default output cap" do
    %{principal: agent} = agent_fixture()
    assert :ok = AgentConfig.ensure_registered()
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
               connection_options: %{"api_key" => "sk-main"}
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
               connection_options: %{"api_key" => "sk-test"}
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

    assert {:error,
            {:provider_options,
             {:invalid_value, "reasoningEffort", "max",
              ["none", "minimal", "low", "medium", "high", "xhigh"]}}} =
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

  test "runtime RPCLane resolves agent conversation context and DB-backed skill overlays" do
    %{principal: agent} = agent_fixture()
    assert {:ok, _defaults} = Ankole.AIAgent.Library.AgentPlugins.Config.defaults()
    assert {:ok, %{skills: 12}} = Library.sync_agent_skills(agent.uid)

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

    {route, turn} = assign_worker_route(agent.uid, "signal-channel:context")
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
    assert context_payload.conversation.key == "signal-channel:context"
    assert context_payload.mission == "Own the next-turn research workflow."
    assert context_payload.soul == "Be exact, calm, and evidence-led."
    assert context_payload.design == "Use cobalt accents and generous whitespace."

    assert {:ok, current_documents} = Library.list_agent_documents(agent.uid)

    assert context_payload.mission_content_hash ==
             current_documents["mission"]["content_hash"]

    assert context_payload.soul_content_hash == current_documents["soul"]["content_hash"]
    assert context_payload.design_content_hash == current_documents["design"]["content_hash"]
    assert Enum.any?(context_payload.skills, &(&1.skill_name == "nano-pdf"))

    assert {:ok, replace_envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "skill-overlay-replace-1",
                 "skills.overlay.replace",
                 %FabricProto.SkillOverlayReplaceRequest{
                   skill_name: "nano-pdf",
                   content: "Prefer page-by-page verification.",
                   expected_content_hash: ""
                 },
                 turn: mixed_case_turn
               ),
               route
             )

    replace_payload = rpc_response_payload!(replace_envelope, FabricProto.SkillOverlayResponse)
    assert replace_payload.has_overlay

    assert Torque.decode!(replace_payload.overlay_json) ==
             %{"text" => "Prefer page-by-page verification."}

    assert {:ok, resolve_envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "skill-overlay-resolve-1",
                 "skills.overlay.resolve",
                 %FabricProto.SkillOverlayResolveRequest{skill_name: "nano-pdf"},
                 turn: mixed_case_turn
               ),
               route
             )

    assert Torque.decode!(
             rpc_response_payload!(resolve_envelope, FabricProto.SkillOverlayResponse).overlay_json
           ) == %{"text" => "Prefer page-by-page verification."}
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

  test "runtime RPCLane accepts overlay writes after active steer bumps revision" do
    %{principal: agent} = agent_fixture()
    assert {:ok, _defaults} = Ankole.AIAgent.Library.AgentPlugins.Config.defaults()
    assert {:ok, %{skills: 12}} = Library.sync_agent_skills(agent.uid)
    {route, turn} = assign_worker_route(agent.uid, "signal-channel:steered-overlay")

    turn.activation_uid
    |> then(&Repo.get_by!(ActorSessionActivation, activation_uid: &1))
    |> Ecto.Changeset.change(%{revision: 1})
    |> Repo.update!()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "skill-overlay-after-steer",
                 "skills.overlay.replace",
                 %FabricProto.SkillOverlayReplaceRequest{
                   skill_name: "nano-pdf",
                   content: "Prefer page-by-page verification after steer.",
                   expected_content_hash: ""
                 },
                 turn: turn
               ),
               route
             )

    assert envelope_body_type(envelope) == :rpc_response, inspect(envelope)
    payload = rpc_response_payload!(envelope, FabricProto.SkillOverlayResponse)
    assert payload.has_overlay

    assert Torque.decode!(payload.overlay_json) ==
             %{"text" => "Prefer page-by-page verification after steer."}
  end

  test "worker auth key is global AppConfigure state" do
    definition = WorkerAuthKey.definition()

    assert :ok = WorkerAuthKey.ensure_registered()
    assert :ok = AppConfigure.delete_global(definition)

    assert {:ok, first} = WorkerAuthKey.ensure()
    assert {:ok, same} = WorkerAuthKey.ensure()
    assert first == same
    assert first =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, "tcp://:" <> rest} = WorkerAuthKey.runtime_fabric_url("tcp://control-plane:6010")
    assert rest == URI.encode_www_form(first) <> "@control-plane:6010"

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
        metadata: %{"brain" => %{"visibility" => "self"}},
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
