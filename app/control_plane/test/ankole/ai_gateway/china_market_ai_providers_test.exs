defmodule Ankole.AIGateway.ChinaMarketAIProvidersTest do
  use ExUnit.Case, async: false

  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.PluginFixtures.KebabAIGatewayProviderKindPlugin
  alias Ankole.PluginFixtures.MissingAIGatewayEmbeddingPreparePlugin
  alias Ankole.PluginFixtures.MissingAIGatewayProviderDefinitionPlugin
  alias Ankole.Plugins.ChinaMarketAIProviders
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.AlibabaCN
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.DeepSeek
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineArk
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineSpeech
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineVisual
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.XiaomiMiMo
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.ZaiCodingPlan

  @zai_default_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) CherryStudio/1.8.2 Chrome/146.0.7680.188 Electron/41.2.1 Safari/537.36"

  test "plugin registers valid declarations for every China-market AI provider" do
    provider_declarations =
      ChinaMarketAIProviders.adapter_declarations()
      |> Enum.filter(&(&1.contract_id == "ai_gateway.provider"))

    assert Enum.map(provider_declarations, & &1.id) == [
             "xiaomi_mimo",
             "volcengine_ark",
             "volcengine_speech",
             "volcengine_visual",
             "alibaba_cn",
             "deepseek",
             "zai_coding_plan"
           ]

    for declaration <- provider_declarations do
      assert :ok == Providers.validate_adapter_declaration(declaration)
    end
  end

  test "invalid plugin providers are rejected instead of skipped" do
    declarations =
      MissingAIGatewayProviderDefinitionPlugin.adapter_declarations() ++
        MissingAIGatewayEmbeddingPreparePlugin.adapter_declarations() ++
        KebabAIGatewayProviderKindPlugin.adapter_declarations()

    assert {:error, {:invalid_ai_gateway_provider_kind, "missing-provider-definition"}} =
             declarations
             |> List.first()
             |> Providers.validate_adapter_declaration()

    assert {:error,
            {:missing_provider_callback, MissingAIGatewayEmbeddingPreparePlugin,
             :prepare_embedding_model, 1}} =
             MissingAIGatewayEmbeddingPreparePlugin.adapter_declarations()
             |> List.first()
             |> Providers.validate_adapter_declaration()

    assert {:error, {:invalid_ai_gateway_provider_kind, "kebab-provider"}} =
             KebabAIGatewayProviderKindPlugin.adapter_declarations()
             |> List.first()
             |> Providers.validate_adapter_declaration()

    assert_raise ArgumentError, ~r/invalid AI Gateway provider declaration/, fn ->
      Providers.refresh_from_adapter_declarations(declarations)
    end
  end

  test "volcengine ark builds an OpenAI-compatible chat request" do
    assert {:ok, spec} =
             prepared_spec(VolcengineArk,
               model: "doubao-seed-1-6",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ark-key"}]},
               provider_options: %{"reasoningEffort" => "medium"},
               request: %{"input" => "hello"},
               stream?: true
             )

    assert spec.api_resolver == :openai_chat_completions
    assert spec.upstream.kind == :http_sse
    assert spec.upstream.url == "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
    assert headers(spec)["authorization"] == "Bearer ark-key"
    assert spec.response_context.model == "doubao-seed-1-6"
    assert spec.response_context.stream == true
    assert spec.response_context.provider_options == %{"reasoning_effort" => "medium"}
  end

  test "alibaba cn preserves DashScope request options for the OpenAI chat resolver" do
    dashscope_options = %{
      "enable_search" => true,
      "search_options" => %{"search_strategy" => "agent"},
      "enable_thinking" => true,
      "thinking_budget" => 4096,
      "repetition_penalty" => 1.1,
      "enable_code_interpreter" => true,
      "vl_high_resolution_images" => true,
      "incremental_output" => true,
      "response_format" => %{"type" => "json_object"}
    }

    assert {:ok, spec} =
             prepared_spec(AlibabaCN,
               model: "qwen-plus",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "dashscope-key"}]
               },
               provider_options: dashscope_options,
               request: %{"input" => "hello"}
             )

    assert spec.api_resolver == :openai_chat_completions

    assert spec.upstream.url ==
             "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

    assert headers(spec)["authorization"] == "Bearer dashscope-key"
    assert spec.response_context.provider_options == dashscope_options
  end

  test "alibaba cn routes speech and transcription to DashScope multimodal generation and OCR to compatible chat" do
    assert {:ok, speech_spec} =
             prepared_spec(AlibabaCN,
               capability: :speech_model,
               model: "qwen3-tts-flash",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ds-key"}]},
               connection_options: %{"query_params" => %{"workspace" => "ws-1"}},
               provider_options: %{"voice" => "Cherry", "language_type" => "Chinese"},
               request: %{"input" => "你好"}
             )

    assert speech_spec.api_resolver == :alibaba_dashscope_speech

    assert speech_spec.upstream.url ==
             "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation?workspace=ws-1"

    assert headers(speech_spec)["authorization"] == "Bearer ds-key"

    assert {:error, %{param: "response_format", code: "unsupported_value"}} =
             prepared_spec(AlibabaCN,
               capability: :speech_model,
               model: "qwen3-tts-flash",
               request: %{"input" => "你好", "response_format" => "mp3"}
             )

    assert {:error, %{param: "speed", code: "unsupported_value"}} =
             prepared_spec(AlibabaCN,
               capability: :speech_model,
               model: "qwen3-tts-flash",
               request: %{"input" => "你好", "speed" => 1.2}
             )

    assert {:ok, asr_spec} =
             prepared_spec(AlibabaCN,
               capability: :transcription_model,
               model: "qwen3-asr-flash",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ds-key"}]},
               request: %{"input_audio" => %{"data" => "UklGRg==", "format" => "wav"}}
             )

    assert asr_spec.api_resolver == :alibaba_dashscope_transcription

    assert asr_spec.upstream.url ==
             "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    assert {:ok, ocr_spec} =
             prepared_spec(AlibabaCN,
               capability: :ocr_model,
               model: "qwen-vl-ocr",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ds-key"}]},
               request: %{"document" => "data:image/png;base64,iVBORw0="}
             )

    assert ocr_spec.api_resolver == :alibaba_dashscope_ocr

    assert ocr_spec.upstream.url ==
             "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

    assert {:error, %{param: "document", code: "unsupported_value"}} =
             prepared_spec(AlibabaCN,
               capability: :ocr_model,
               model: "qwen-vl-ocr",
               request: %{"document" => "data:application/pdf;base64,JVBERi0="}
             )

    assert {:error, %{param: "pages", code: "unsupported_value"}} =
             prepared_spec(AlibabaCN,
               capability: :ocr_model,
               model: "qwen-vl-ocr",
               request: %{"document" => "data:image/png;base64,iVBORw0=", "pages" => [0]}
             )
  end

  test "volcengine speech validates dual auth modes and prepares V3 TTS and ASR headers" do
    definition = VolcengineSpeech.provider_definition()
    assert Providers.credential_required?(definition)

    assert {:ok, _} =
             Providers.normalize_credential_options("volcengine_speech", %{
               "api_key" => "volc-api-key"
             })

    assert {:ok, _} =
             Providers.normalize_credential_options("volcengine_speech", %{
               "app_key" => "app-123",
               "access_key" => "token-456"
             })

    assert {:error, {:credential_options, {:required, "access_key"}}} =
             Providers.normalize_credential_options("volcengine_speech", %{"app_key" => "app-123"})

    assert {:error, {:credential_options, {:required, "api_key"}}} =
             Providers.normalize_credential_options("volcengine_speech", %{})

    assert {:ok, tts_spec} =
             prepared_spec(VolcengineSpeech,
               capability: :speech_model,
               model: "seed-tts-2.0",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "volc-api-key"}]
               },
               provider_options: %{"voice" => "zh_female_vv_uranus_bigtts"},
               request: %{"input" => "你好火山语音", "speed" => 1.25}
             )

    assert tts_spec.api_resolver == :volcengine_speech
    assert tts_spec.upstream.url == "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
    assert headers(tts_spec)["x-api-key"] == "volc-api-key"
    assert headers(tts_spec)["x-api-resource-id"] == "seed-tts-2.0"
    assert is_binary(headers(tts_spec)["x-api-request-id"])

    assert {:error, %{param: "voice", code: "missing_required_parameter"}} =
             prepared_spec(VolcengineSpeech,
               capability: :speech_model,
               model: "seed-tts-2.0",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "volc-api-key"}]
               },
               request: %{"input" => "你好"}
             )

    assert {:error, %{param: "response_format", code: "unsupported_value"}} =
             prepared_spec(VolcengineSpeech,
               capability: :speech_model,
               model: "seed-tts-2.0",
               provider_options: %{"voice" => "zh_female_vv_uranus_bigtts"},
               request: %{"input" => "你好", "response_format" => "wav"}
             )

    assert {:error, %{param: "speed", code: "unsupported_value"}} =
             prepared_spec(VolcengineSpeech,
               capability: :speech_model,
               model: "seed-tts-2.0",
               provider_options: %{"voice" => "zh_female_vv_uranus_bigtts"},
               request: %{"input" => "你好", "speed" => 2.5}
             )

    assert {:ok, asr_spec} =
             prepared_spec(VolcengineSpeech,
               capability: :transcription_model,
               model: "bigmodel",
               credential_pool: %{
                 "entries" => [
                   %{"label" => "Default", "app_key" => "app-123", "access_key" => "tok-456"}
                 ]
               },
               request: %{"input_audio" => %{"data" => "UklGRg==", "format" => "wav"}}
             )

    assert asr_spec.api_resolver == :volcengine_transcription

    assert asr_spec.upstream.url ==
             "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"

    assert headers(asr_spec)["x-api-app-key"] == "app-123"
    assert headers(asr_spec)["x-api-access-key"] == "tok-456"
    assert headers(asr_spec)["x-api-resource-id"] == "volc.bigasr.auc_turbo"
    assert headers(asr_spec)["x-api-sequence"] == "-1"
  end

  test "volcengine visual prepares signed OCRNormal and OCRPdf requests" do
    credentials = %{
      "entries" => [
        %{
          "label" => "Default",
          "access_key_id" => "AKLTVOLC",
          "secret_access_key" => "sk-volc"
        }
      ]
    }

    assert {:ok, img_spec} =
             prepared_spec(VolcengineVisual,
               capability: :ocr_model,
               model: "ocr-normal",
               credential_pool: credentials,
               request: %{"document" => "data:image/png;base64,iVBORw0="}
             )

    assert img_spec.api_resolver == :volcengine_visual_ocr

    assert img_spec.upstream.url ==
             "https://visual.volcengineapi.com/?Action=OCRNormal&Version=2020-08-26"

    assert img_spec.upstream.volcengine_sigv4 == %{
             access_key_id: "AKLTVOLC",
             secret_access_key: "sk-volc",
             region: "cn-north-1",
             service: "cv"
           }

    assert {:ok, pdf_spec} =
             prepared_spec(VolcengineVisual,
               capability: :ocr_model,
               model: "ocr-normal",
               credential_pool: credentials,
               request: %{"document" => "data:application/pdf;base64,JVBERi0="}
             )

    assert pdf_spec.upstream.url ==
             "https://visual.volcengineapi.com/?Action=OCRPdf&Version=2020-08-26"

    assert {:error, %{param: "pages", code: "unsupported_value"}} =
             prepared_spec(VolcengineVisual,
               capability: :ocr_model,
               model: "ocr-pdf",
               credential_pool: credentials,
               request: %{"document" => "data:application/pdf;base64,JVBERi0=", "pages" => [0]}
             )
  end

  test "deepseek prepares chat, speech, transcription, and OCR requests without doubling /v1" do
    provider = %Provider{
      id: "deepseek-main",
      provider_kind: "deepseek",
      connection_options: %{},
      credential_pool: %{"entries" => []}
    }

    assert {:ok, models} = ModelMetadata.list_provider_model_metadata(provider)
    assert Enum.any?(models, &String.starts_with?(&1["id"], "deepseek-"))

    assert {:ok, chat_spec} =
             prepared_spec(DeepSeek,
               model: "deepseek-chat",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ds-key"}]},
               request: %{"input" => "hello"}
             )

    assert chat_spec.api_resolver == :openai_chat_completions
    assert chat_spec.upstream.url == "https://api.deepseek.com/chat/completions"
    assert headers(chat_spec)["authorization"] == "Bearer ds-key"

    assert {:ok, tts_spec} =
             prepared_spec(DeepSeek,
               capability: :speech_model,
               model: "deepseek-tts",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ds-key"}]},
               connection_options: %{"base_url" => "https://api.deepseek.com/v1"},
               provider_options: %{"voice" => "stella", "filter_markdown" => true},
               request: %{"input" => "Hello DeepSeek"}
             )

    assert tts_spec.api_resolver == :deepseek_speech
    assert tts_spec.upstream.url == "https://api.deepseek.com/v1/tools/tts"

    assert {:error, %{param: "response_format", code: "unsupported_value"}} =
             prepared_spec(DeepSeek,
               capability: :speech_model,
               model: "deepseek-tts",
               request: %{"input" => "Hello", "response_format" => "mp3"}
             )

    assert {:ok, asr_spec} =
             prepared_spec(DeepSeek,
               capability: :transcription_model,
               model: "deepseek-asr",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ds-key"}]},
               request: %{"input_audio" => %{"data" => "UklGRg==", "format" => "wav"}}
             )

    assert asr_spec.api_resolver == :deepseek_transcription
    assert asr_spec.upstream.url == "https://api.deepseek.com/v1/tools/asr"

    assert {:ok, ocr_spec} =
             prepared_spec(DeepSeek,
               capability: :ocr_model,
               model: "deepseek-ocr",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ds-key"}]},
               provider_options: %{"purpose" => "rich_layout_recognition"},
               request: %{"document" => "data:application/pdf;base64,JVBERi0="}
             )

    assert ocr_spec.api_resolver == :deepseek_ocr
    assert ocr_spec.upstream.url == "https://api.deepseek.com/v1/tools/ocr"
  end

  test "xiaomi mimo token plan rewrites the endpoint and keeps billing out of the body" do
    definition = XiaomiMiMo.provider_definition()
    billing_plan = Enum.find(definition.settings, &(&1.key == :xiaomi_mimo_billing_plan))

    assert billing_plan.scope == :connection

    assert {:error, {:provider_options, {:unknown_keys, ["xiaomi_mimo_billing_plan"]}}} =
             Providers.validate_runtime_provider_options("xiaomi_mimo", %{
               "xiaomi_mimo_billing_plan" => "token_plan"
             })

    assert {:ok, spec} =
             prepared_spec(XiaomiMiMo,
               model: "mimo-v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "mimo-key"}]
               },
               connection_options: %{
                 "xiaomi_mimo_billing_plan" => "token_plan"
               },
               provider_options: %{"thinking" => %{"type" => "enabled"}},
               request: %{"input" => "hello"}
             )

    assert spec.api_resolver == :anthropic_messages
    assert spec.upstream.url == "https://token-plan-cn.xiaomimimo.com/anthropic/v1/messages"
    assert headers(spec)["api-key"] == "mimo-key"
    # The kernel chooses the Anthropic version from the target model.
    refute Map.has_key?(headers(spec), "anthropic-version")

    assert spec.response_context.provider_options == %{
             "thinking" => %{"type" => "enabled"}
           }
  end

  test "xiaomi mimo token plan reaches an overseas cluster over a stored default host" do
    assert {:ok, spec} =
             prepared_spec(XiaomiMiMo,
               model: "mimo-v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "tp-key"}]
               },
               connection_options: %{
                 "base_url" => "https://api.xiaomimimo.com/anthropic",
                 "xiaomi_mimo_billing_plan" => "token_plan_sgp"
               },
               request: %{"input" => "hello"}
             )

    assert spec.upstream.url == "https://token-plan-sgp.xiaomimimo.com/anthropic/v1/messages"
  end

  test "zai coding plan preserves thinking options and uses the longer timeout" do
    assert {:ok, spec} =
             prepared_spec(ZaiCodingPlan,
               model: "glm-4.7",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "zai-key"}]},
               provider_options: %{"thinking" => %{"type" => "disabled"}},
               request: %{"input" => "hello"},
               stream?: true
             )

    assert spec.api_resolver == :openai_chat_completions
    assert spec.upstream.url == "https://api.z.ai/api/coding/paas/v4/chat/completions"
    assert headers(spec)["authorization"] == "Bearer zai-key"
    assert headers(spec)["user-agent"] == @zai_default_user_agent
    assert spec.response_context.provider_options == %{"thinking" => %{"type" => "disabled"}}

    assert spec.upstream.timeout == %{
             connect_ms: 300_000,
             first_byte_ms: 300_000,
             idle_ms: 300_000,
             total_ms: nil
           }
  end

  test "zai coding plan can route through the China server endpoint" do
    assert "china_server" in setting_keys(ZaiCodingPlan.provider_definition())

    assert {:ok, spec} =
             prepared_spec(ZaiCodingPlan,
               model: "glm-4.7",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "zai-key"}]
               },
               connection_options: %{"china_server" => true},
               provider_options: %{"thinking" => %{"type" => "enabled"}},
               request: %{"input" => "hello"}
             )

    assert spec.upstream.url == "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"
    assert headers(spec)["authorization"] == "Bearer zai-key"
    assert headers(spec)["user-agent"] == @zai_default_user_agent
    assert spec.response_context.provider_options == %{"thinking" => %{"type" => "enabled"}}
  end

  test "zai coding plan user agent is operator-configurable" do
    assert {:ok, spec} =
             prepared_spec(ZaiCodingPlan,
               model: "glm-4.7",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "zai-key"}]
               },
               connection_options: %{
                 "user_agent" => "AnkoleProviderSmoke/1.0"
               },
               provider_options: %{"thinking" => %{"type" => "disabled"}},
               request: %{"input" => "hello"}
             )

    assert headers(spec)["user-agent"] == "AnkoleProviderSmoke/1.0"
  end

  defp prepared_spec(module, opts) do
    definition = module.provider_definition()
    capability_kind = Keyword.get(opts, :capability, :language_model)

    {:ok, capability} =
      Ankole.AIGateway.ProviderDefinition.capability(definition, capability_kind)

    credential_keys = Providers.credential_option_keys(definition)

    credential =
      opts
      |> Keyword.get(:credential_pool, %{})
      |> Map.get("entries", [])
      |> List.first()
      |> case do
        entry when is_map(entry) -> Map.take(entry, credential_keys)
        _entry -> %{}
      end

    runtime = %{
      "provider_kind" => definition.provider_kind,
      "model" => Keyword.fetch!(opts, :model),
      "connection_options" =>
        Keyword.get(opts, :connection_options, %{})
        |> Map.merge(credential),
      "provider_options" => Keyword.get(opts, :provider_options, %{})
    }

    with {:ok, ctx} <-
           PrepareContext.build(
             definition,
             capability_kind,
             runtime,
             Keyword.fetch!(opts, :request),
             stream?: Keyword.get(opts, :stream?, false)
           ) do
      module
      |> apply(capability.prepare, [ctx])
      |> to_spec()
    end
  end

  defp to_spec(%UniversalAIRequest{} = request), do: UniversalAIRequest.to_spec(request)
  defp to_spec({:ok, %UniversalAIRequest{} = request}), do: UniversalAIRequest.to_spec(request)
  defp to_spec({:error, _reason} = error), do: error

  defp setting_keys(%{settings: settings}) do
    Enum.map(settings, &Atom.to_string(&1.key))
  end

  defp headers(spec) do
    Map.new(spec.upstream.headers, fn {key, value} -> {String.downcase(key), value} end)
  end
end
