defmodule Ankole.AIGateway.OpenAIRequestOptionsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.OpenAIRequestOptions
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Providers.AgentBullCloud
  alias Ankole.AIGateway.Providers.AzureOpenAI
  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.Providers.ChatGPTSubscription
  alias Ankole.AIGateway.Providers.Claude
  alias Ankole.AIGateway.Providers.GoogleAIStudioOpenAI
  alias Ankole.AIGateway.Providers.OpenAI
  alias Ankole.AIGateway.Providers.OpenAICompatible
  alias Ankole.AIGateway.Providers.OpenRouter
  alias Ankole.AIGateway.Providers.TypeSafe
  alias Ankole.AIGateway.UniversalAIRequest

  test "Azure Foundry v1 prepares both inference protocols, but other Foundry protocols remain rejected" do
    for suffix <- ["/openai/v1", "/openai/v1/"], endpoint <- ["chat_completions", "responses"] do
      assert {:ok, ctx} =
               Ankole.AIGateway.PrepareContext.build(
                 AzureOpenAI.provider_definition(),
                 :language_model,
                 %{
                   "model" => "deployed-model",
                   "connection_options" => %{
                     "base_url" => "https://resource.services.ai.azure.com" <> suffix,
                     "endpoint_kind" => endpoint,
                     "api_key" => "fixture"
                   }
                 },
                 %{"input" => "hello", "max_output_tokens" => 64}
               )

      assert %UniversalAIRequest{} = prepared = AzureOpenAI.prepare_language_model(ctx)
      assert prepared.include_model
      assert {"api-key", "fixture"} in prepared.headers

      if endpoint == "responses" do
        assert prepared.path == "responses"
        refute Map.has_key?(prepared.ctx.request, "__ankole_chat_max_tokens_field")
      else
        assert prepared.path == "chat/completions"
        assert prepared.ctx.request["__ankole_chat_max_tokens_field"] == "max_completion_tokens"

        legacy =
          AzureOpenAI.prepare_language_model(
            put_in(ctx.settings[:maxTokensParameter], "max_tokens")
          )

        assert legacy.ctx.request["__ankole_chat_max_tokens_field"] == "max_tokens"
      end

      unsupported =
        put_in(ctx.settings[:base_url], "https://resource.services.ai.azure.com/models")

      assert {:error, :unsupported_azure_foundry_endpoint} =
               AzureOpenAI.prepare_language_model(unsupported)
    end
  end

  test "provider definitions expose only accepted OpenAI output choices" do
    assert setting(OpenAI, :reasoningSummary) ==
             {:select, ~w(auto concise detailed), true}

    assert setting(AzureOpenAI, :reasoningSummary) ==
             {:select, ~w(auto concise detailed), true}

    assert setting(OpenAI, :textVerbosity) == {:select, ~w(low medium high), false}
    assert setting(AzureOpenAI, :textVerbosity) == {:select, ~w(low medium high), false}

    for provider <- [ChatGPTSubscription, AzureOpenAI, OpenAI, OpenAICompatible] do
      assert setting(provider, :serviceTier) == {nil, ~w(fast flex), true}
    end

    for provider_kind <- ~w(chatgpt_subscription azure_openai openai openai_compatible) do
      assert :ok =
               Providers.validate_runtime_provider_options(provider_kind, %{
                 "serviceTier" => "fast"
               })

      assert :ok =
               Providers.validate_runtime_provider_options(provider_kind, %{
                 "serviceTier" => "provider-native-tier"
               })
    end

    assert :ok =
             Providers.validate_runtime_provider_options("openai", %{
               "reasoningSummary" => "auto",
               "textVerbosity" => "high"
             })

    assert {:error,
            {:provider_options,
             {:invalid_value, "textVerbosity", "verbose", ["low", "medium", "high"]}}} =
             Providers.validate_runtime_provider_options("openai", %{
               "textVerbosity" => "verbose"
             })

    for provider <- [AzureOpenAI, OpenAI] do
      assert setting(provider, :truncation) == {:select, ~w(auto disabled), true}
    end

    assert setting(OpenAI, :promptCacheRetention) == {:select, ~w(in_memory 24h), true}

    assert {:error,
            {:provider_options,
             {:invalid_value, "promptCacheRetention", "1h", ["in_memory", "24h"]}}} =
             Providers.validate_runtime_provider_options("openai", %{
               "promptCacheRetention" => "1h"
             })
  end

  test "sends the fast service tier as OpenAI's priority tier" do
    assert OpenAIRequestOptions.put_service_tier(%{"serviceTier" => "fast"}) ==
             %{"service_tier" => "priority"}

    assert OpenAIRequestOptions.put_service_tier(%{"serviceTier" => "flex"}) ==
             %{"service_tier" => "flex"}

    assert OpenAIRequestOptions.put_service_tier(%{"serviceTier" => "provider-native-tier"}) ==
             %{"service_tier" => "provider-native-tier"}

    assert OpenAIRequestOptions.put_service_tier(%{"user" => "u"}) == %{"user" => "u"}
  end

  test "maps Responses output controls into nested native objects" do
    request =
      request(%{
        "reasoning" => %{"effort" => "high"},
        "reasoningSummary" => "detailed",
        "serviceTier" => "fast",
        "textVerbosity" => "low",
        "promptCacheKey" => "route-a",
        "promptCacheOptions" => %{"mode" => "explicit"},
        "promptCacheRetention" => "24h",
        "safetyIdentifier" => "user-123",
        "contextManagement" => [%{"type" => "compaction"}],
        "truncation" => "auto"
      })

    assert %UniversalAIRequest{provider_options: options} =
             OpenAIRequestOptions.put_provider_options(request, :responses)

    assert options == %{
             "reasoning" => %{"effort" => "high", "summary" => "detailed"},
             "service_tier" => "priority",
             "text" => %{"verbosity" => "low"},
             "prompt_cache_key" => "route-a",
             "prompt_cache_options" => %{"mode" => "explicit"},
             "prompt_cache_retention" => "24h",
             "safety_identifier" => "user-123",
             "context_management" => [%{"type" => "compaction"}],
             "truncation" => "auto"
           }
  end

  test "maps Chat Completions verbosity and rejects Responses-only options" do
    assert %UniversalAIRequest{provider_options: options} =
             request(%{
               "reasoning_effort" => "high",
               "serviceTier" => "flex",
               "textVerbosity" => "medium",
               "promptCacheKey" => "route-a",
               "promptCacheOptions" => %{"mode" => "explicit"},
               "promptCacheRetention" => "24h",
               "safetyIdentifier" => "user-123"
             })
             |> OpenAIRequestOptions.put_provider_options(:chat_completions)

    assert options == %{
             "reasoning_effort" => "high",
             "service_tier" => "flex",
             "verbosity" => "medium",
             "prompt_cache_key" => "route-a",
             "prompt_cache_options" => %{"mode" => "explicit"},
             "prompt_cache_retention" => "24h",
             "safety_identifier" => "user-123"
           }

    openai_language =
      prepared(OpenAI, %{
        "promptCacheOptions" => %{"mode" => "explicit"},
        "safetyIdentifier" => "user-123"
      })

    assert openai_language.provider_options["prompt_cache_options"] == %{"mode" => "explicit"}
    assert openai_language.provider_options["safety_identifier"] == "user-123"
    refute Map.has_key?(openai_language.provider_options, "promptCacheOptions")
    refute Map.has_key?(openai_language.provider_options, "safetyIdentifier")

    for {option, value} <- [
          {"reasoningSummary", "auto"},
          {"truncation", "auto"},
          {"contextManagement", [%{"type" => "compaction"}]}
        ] do
      assert {:error, {:unsupported_provider_option, ^option, "chat_completions"}} =
               request(%{option => value})
               |> OpenAIRequestOptions.put_provider_options(:chat_completions)
    end
  end

  test "request options reach other providers under their upstream field names" do
    # These public names had no upstream field, so a stored value would only make
    # the upstream reject the request.
    for {provider_kind, option} <- [
          {"openai", "strictJSONSchema"},
          {"openai", "systemMessageMode"},
          {"openai", "forceReasoning"},
          {"openai", "allowedTools"},
          {"azure_openai", "strictJSONSchema"},
          {"openai_compatible", "strictJSONSchema"},
          {"google_ai_studio_openai", "strictJSONSchema"},
          {"google_ai_studio_openai", "textVerbosity"},
          {"openrouter", "strictJSONSchema"},
          {"claude", "structuredOutputMode"},
          {"claude", "toolStreaming"},
          {"claude", "taskBudget"},
          {"claude", "anthropicBeta"},
          {"claude", "contextManagement"}
        ] do
      assert {:error, _reason} =
               Providers.validate_runtime_provider_options(provider_kind, %{option => true})
    end

    assert {:select, ~w(low medium high xhigh max), false} = setting(Claude, :reasoningEffort)

    claude =
      prepared(Claude, %{"inferenceGeo" => "us", "speed" => "fast", "reasoningEffort" => "low"})

    assert claude.provider_options == %{
             "inference_geo" => "us",
             "speed" => "fast",
             "output_config" => %{"effort" => "low"},
             "cache_control" => %{"type" => "ephemeral"}
           }

    assert {"anthropic-beta", "fast-mode-2026-02-01"} in claude.headers
    refute Enum.any?(prepared(Claude, %{}).headers, &(elem(&1, 0) == "anthropic-beta"))

    openrouter =
      prepared(OpenRouter, %{"textVerbosity" => "low", "reasoningEffort" => "medium"})

    assert openrouter.provider_options == %{
             "verbosity" => "low",
             "reasoning" => %{"effort" => "medium"}
           }
  end

  test "a fast Claude request keeps the operator's beta flags first" do
    {:ok, ctx} =
      PrepareContext.build(
        Claude.provider_definition(),
        :language_model,
        %{
          "model" => "claude-opus-5",
          "connection_options" => %{
            "api_key" => "fixture",
            "anthropic_beta" => "context-1m-2025-08-07, fast-mode-2026-02-01"
          },
          "provider_options" => %{"speed" => "fast"}
        },
        %{"input" => "hello"}
      )

    assert {"anthropic-beta", "context-1m-2025-08-07,fast-mode-2026-02-01"} in Claude.prepare_language_model(
             ctx
           ).headers
  end

  test "Azure OpenAI defaults to the Responses endpoint" do
    assert setting(AzureOpenAI, :endpoint_kind) ==
             {:select, ~w(responses chat_completions), false}

    assert Providers.responses_endpoint?("azure_openai", %{})
    assert Providers.responses_endpoint?("azure_openai", %{"endpoint_kind" => "responses"})
    refute Providers.responses_endpoint?("azure_openai", %{"endpoint_kind" => "chat_completions"})
    refute Providers.responses_endpoint?("openai_compatible", %{})

    {:ok, ctx} =
      PrepareContext.build(
        AzureOpenAI.provider_definition(),
        :language_model,
        %{
          "model" => "gpt-6.1-sol",
          "connection_options" => %{
            "base_url" => "https://resource.services.ai.azure.com/openai/v1",
            "api_key" => "fixture"
          }
        },
        %{"input" => "hello"}
      )

    assert %UniversalAIRequest{path: "responses", api_resolver: :openai_responses} =
             AzureOpenAI.prepare_language_model(ctx)

    # A deployment-style resource speaks Responses on the resource path, and
    # Azure reads the body model as the configured deployment name.
    {:ok, deployment_ctx} =
      PrepareContext.build(
        AzureOpenAI.provider_definition(),
        :language_model,
        %{
          "model" => "gpt-6.1-sol",
          "connection_options" => %{
            "base_url" => "https://resource.openai.azure.com",
            "deployment" => "sol-prod",
            "api_key" => "fixture"
          }
        },
        %{"input" => "hello"}
      )

    prepared = AzureOpenAI.prepare_language_model(deployment_ctx)
    assert prepared.path == "openai/responses?api-version=2025-04-01-preview"
    assert prepared.include_model
    assert prepared.ctx.model == "sol-prod"
  end

  test "request settings are offered only on the profiles of the capabilities that read them" do
    capabilities = fn module, key ->
      Enum.find(module.provider_definition().settings, &(&1.key == key)).capabilities
    end

    assert capabilities.(OpenRouter, :reasoningEffort) == [:language_model]
    assert capabilities.(OpenRouter, :textVerbosity) == [:language_model]

    assert capabilities.(OpenRouter, :user) == [
             :language_model,
             :embedding_model,
             :rerank_model,
             :image_generate
           ]

    for key <- [:taskType, :title, :outputDimensionality, :autoTruncate] do
      assert capabilities.(GoogleAIStudioOpenAI, key) == [:embedding_model]
    end

    assert capabilities.(GoogleAIStudioOpenAI, :reasoningEffort) == [:language_model]

    for key <- [:sources, :timeRange, :skip_cache] do
      assert capabilities.(AgentBullCloud, key) == [:web_search]
    end

    for key <- [:reasoningEffort, :serviceTier, :textVerbosity, :truncation] do
      assert capabilities.(AgentBullCloud, key) == [:language_model]
    end
  end

  test "maps Decisions options and rejects language-only controls" do
    assert %UniversalAIRequest{provider_options: options} =
             request(%{
               "promptCacheKey" => "route-a",
               "promptCacheOptions" => %{"mode" => "explicit"},
               "safetyIdentifier" => "user-123"
             })
             |> OpenAIRequestOptions.put_provider_options(:decisions)

    assert options == %{
             "prompt_cache_key" => "route-a",
             "prompt_cache_options" => %{"mode" => "explicit"},
             "safety_identifier" => "user-123"
           }

    for {option, value} <- [
          {"reasoningEffort", "high"},
          {"reasoningSummary", "auto"},
          {"serviceTier", "fast"},
          {"textVerbosity", "low"},
          {"truncation", "auto"},
          {"contextManagement", %{}},
          {"promptCacheRetention", "24h"}
        ] do
      assert {:error, {:unsupported_provider_option, ^option, "decisions"}} =
               request(%{option => value})
               |> OpenAIRequestOptions.put_provider_options(:decisions)
    end
  end

  test "Azure decision requests resolve every Foundry base URL form and the deployment" do
    root = "https://resource.services.ai.azure.com"

    for {suffix, expected_base, expected_path} <- [
          {"/providers/microsoft/v1/systemone", root <> "/providers/microsoft/v1", "systemone"},
          {"/providers/microsoft/v1", root <> "/providers/microsoft/v1", "systemone"},
          {"/openai/v1", root, "providers/microsoft/v1/systemone"},
          {"/openai", root, "providers/microsoft/v1/systemone"},
          {"", root, "providers/microsoft/v1/systemone"}
        ] do
      prepared =
        decision_prepared(
          AzureOpenAI,
          "microsoft-decision-1",
          %{
            "base_url" => root <> suffix,
            "deployment" => "foundry-deployment",
            "api_key" => "azure-key",
            "query_params" => %{"api-version" => "preview"}
          },
          %{"state" => nil, "questions" => %{}}
        )

      assert prepared.ctx.model == "foundry-deployment"
      assert prepared.ctx.settings.base_url == expected_base
      assert prepared.path == expected_path
      assert prepared.api_resolver == :systemone_decision
      assert {"api-key", "azure-key"} in prepared.headers
      assert {:ok, spec} = UniversalAIRequest.to_spec(prepared)
      assert spec.response_context.model == "foundry-deployment"
      assert spec.upstream.url == expected_base <> "/" <> expected_path <> "?api-version=preview"

      assert {:error, %Ankole.AIGateway.OpenAIError{code: "unsupported_value"}} =
               decision_prepared(
                 AzureOpenAI,
                 "microsoft-decision-1",
                 %{"base_url" => root, "api_key" => "azure-key"},
                 %{"state" => nil, "questions" => %{}, "images" => ["data:image/png;base64,cG5n"]}
               )
    end

    for {option, value} <- [
          {"maxTokensParameter", "max_tokens"},
          {"reasoningEffort", "high"},
          {"reasoningSummary", "auto"},
          {"serviceTier", "fast"},
          {"textVerbosity", "low"},
          {"truncation", "auto"}
        ] do
      assert {:error, {:unsupported_provider_option, ^option, "decisions"}} =
               decision_prepared(
                 AzureOpenAI,
                 "microsoft-decision-1",
                 %{"base_url" => root, "api_key" => "azure-key"},
                 %{"state" => nil, "questions" => %{}},
                 %{option => value}
               )
    end
  end

  test "TypeSafe prepares SystemOne headers and rejects unsupported images" do
    prepared =
      decision_prepared(
        TypeSafe,
        "jev-latest",
        %{"base_url" => "https://api.typesafe.ai/v1/systemone/", "api_key" => "typesafe-key"},
        %{
          "state" => nil,
          "questions" => %{},
          "images" => ["data:image/png;base64,cG5n"]
        },
        %{"longContext" => true}
      )

    assert prepared.path == "systemone"
    assert prepared.ctx.settings.base_url == "https://api.typesafe.ai/v1"
    assert {:ok, spec} = UniversalAIRequest.to_spec(prepared)
    assert spec.upstream.url == "https://api.typesafe.ai/v1/systemone"
    assert prepared.api_resolver == :systemone_decision
    assert {"authorization", "Bearer typesafe-key"} in prepared.headers
    assert {"TypeSafe-Danger-Zone-Images", "true"} in prepared.headers
    assert {"TypeSafe-Danger-Zone-Long-Context", "true"} in prepared.headers
    refute TypeSafe.provider_definition().base_url_advanced?

    for connection <- [
          %{"base_url" => "http://systemone.test/v1", "allow_images" => false},
          %{"base_url" => "http://systemone.test/v1"}
        ] do
      image =
        if connection["allow_images"] == false,
          do: "data:image/png;base64,cG5n",
          else: "data:image/webp;base64,d2VicA=="

      assert {:error, %Ankole.AIGateway.OpenAIError{code: "unsupported_value"}} =
               decision_prepared(
                 TypeSafe,
                 "jev-latest",
                 connection,
                 %{"state" => nil, "questions" => %{}, "images" => [image]}
               )
    end
  end

  test "OpenRouter permits Jev images but rejects them for Microsoft Decision" do
    request = %{
      "state" => nil,
      "questions" => %{},
      "images" => ["data:image/png;base64,cG5n"]
    }

    assert {:error, %Ankole.AIGateway.OpenAIError{code: "unsupported_value"}} =
             decision_prepared(
               OpenRouter,
               "microsoft/microsoft-decision-1",
               %{"base_url" => "https://openrouter.ai/api/v1", "api_key" => "or-key"},
               request
             )

    prepared =
      decision_prepared(
        OpenRouter,
        "typesafe/jev-latest",
        %{"base_url" => "https://openrouter.ai/api/v1", "api_key" => "or-key"},
        request,
        %{"provider" => %{"only" => ["typesafe"]}}
      )

    assert prepared.path == "systemone"
    assert prepared.ctx.provider_options == %{"provider" => %{"only" => ["typesafe"]}}
    assert {"authorization", "Bearer or-key"} in prepared.headers
    assert {"TypeSafe-Danger-Zone-Images", "true"} in prepared.headers

    for {option, value} <- [
          {"user", "end-user-1"},
          {"reasoningEffort", "high"},
          {"textVerbosity", "low"}
        ] do
      assert {:error, {:unsupported_provider_option, ^option, "decisions"}} =
               decision_prepared(
                 OpenRouter,
                 "typesafe/jev-latest",
                 %{"base_url" => "https://openrouter.ai/api/v1", "api_key" => "or-key"},
                 %{"state" => nil, "questions" => %{}},
                 %{option => value}
               )
    end
  end

  defp decision_prepared(provider, model, connection_options, request, provider_options \\ %{}) do
    {:ok, ctx} =
      PrepareContext.build(
        provider.provider_definition(),
        :decision_model,
        %{
          "model" => model,
          "connection_options" => connection_options,
          "provider_options" => provider_options
        },
        request
      )

    provider.prepare_decision_model(ctx)
  end

  defp prepared(provider, provider_options) do
    {:ok, ctx} =
      PrepareContext.build(
        provider.provider_definition(),
        :language_model,
        %{
          "model" => "fixture-model",
          "connection_options" => %{"api_key" => "fixture"},
          "provider_options" => provider_options
        },
        %{"input" => "hello"}
      )

    provider.prepare_language_model(ctx)
  end

  defp request(provider_options) do
    %UniversalAIRequest{
      ctx: %{},
      path: "responses",
      api_resolver: :openai_responses,
      provider_options: provider_options
    }
  end

  defp setting(module, key) do
    setting = Enum.find(module.provider_definition().settings, &(&1.key == key))
    {setting.type, setting.options, setting.advanced?}
  end
end
