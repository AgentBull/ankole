defmodule Ankole.AIGateway.ChinaMarketAIProvidersTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.ProviderDefinition
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.Plugins.ChinaMarketAIProviders
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.AlibabaCN
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.VolcengineArk
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.XiaomiMiMo
  alias Ankole.Plugins.ChinaMarketAIProviders.Providers.ZaiCodingPlan
  alias Ankole.Plugins.Spec

  @zai_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) CherryStudio/1.8.2 Chrome/146.0.7680.188 Electron/41.2.1 Safari/537.36"
  @providers [
    {"xiaomi_mimo", XiaomiMiMo, "https://api.xiaomimimo.com/anthropic", :anthropic_messages},
    {"volcengine_ark", VolcengineArk, "https://ark.cn-beijing.volces.com/api/v3",
     :openai_chat_completions},
    {"alibaba_cn", AlibabaCN, "https://dashscope.aliyuncs.com/compatible-mode/v1",
     :openai_chat_completions},
    {"zai_coding_plan", ZaiCodingPlan, "https://api.z.ai/api/coding/paas/v4",
     :openai_chat_completions}
  ]

  test "plugin declaration registers all AI Gateway provider adapters" do
    assert {:ok, spec} = Spec.from_module(ChinaMarketAIProviders)
    assert spec.id == "china-market-ai-providers"
    assert spec.children == []

    declarations = Map.new(spec.adapter_declarations, &{&1.id, &1})

    for {provider_id, module, _base_url, _resolver} <- @providers do
      assert %{
               contract_id: "ai_gateway.provider",
               id: ^provider_id,
               plugin_id: "china-market-ai-providers",
               module: ^module
             } = Map.fetch!(declarations, provider_id)
    end
  end

  test "provider definitions expose exact ids, defaults, and language-model capability" do
    for {provider_id, module, base_url, resolver} <- @providers do
      definition = module.provider_definition()

      assert definition.provider_kind == provider_id
      assert definition.module == module
      assert definition.base_url == base_url
      assert {:ok, capability} = ProviderDefinition.capability(definition, :language_model)
      assert capability.kind == :language_model
      assert capability.upstream == :sse
      assert capability.api_resolver == resolver
      assert capability.prepare == :prepare_language_model
      assert "api_key" in setting_keys(definition)
    end
  end

  test "volcengine ark builds an OpenAI-compatible chat request" do
    assert {:ok, spec} =
             prepared_spec(VolcengineArk,
               model: "doubao-seed-1-6",
               connection_options: %{"api_key" => "ark-key"},
               provider_options: %{"reasoning" => %{"effort" => "high"}},
               request: %{"input" => "hello"},
               stream?: true
             )

    assert spec.api_resolver == :openai_chat_completions
    assert spec.upstream.kind == :http_sse
    assert spec.upstream.url == "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
    assert headers(spec)["authorization"] == "Bearer ark-key"
    assert spec.response_context.model == "doubao-seed-1-6"
    assert spec.response_context.stream == true
    assert spec.response_context.provider_options == %{"reasoning" => %{"effort" => "high"}}
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
               connection_options: %{"api_key" => "dashscope-key"},
               provider_options: dashscope_options,
               request: %{"input" => "hello"}
             )

    assert spec.api_resolver == :openai_chat_completions

    assert spec.upstream.url ==
             "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

    assert headers(spec)["authorization"] == "Bearer dashscope-key"
    assert spec.response_context.provider_options == dashscope_options
  end

  test "xiaomi mimo token plan rewrites the endpoint and keeps billing out of the body" do
    assert {:ok, spec} =
             prepared_spec(XiaomiMiMo,
               model: "mimo-v1",
               connection_options: %{"api_key" => "mimo-key"},
               provider_options: %{
                 "xiaomi_mimo_billing_plan" => "token_plan",
                 "thinking" => %{"type" => "enabled"}
               },
               request: %{"input" => "hello"}
             )

    assert spec.api_resolver == :anthropic_messages
    assert spec.upstream.url == "https://token-plan-cn.xiaomimimo.com/anthropic/v1/messages"
    assert headers(spec)["x-api-key"] == "mimo-key"
    assert headers(spec)["anthropic-version"] == "2023-06-01"

    assert spec.response_context.provider_options == %{
             "thinking" => %{"type" => "enabled"}
           }
  end

  test "zai coding plan preserves thinking options and uses the longer timeout" do
    assert {:ok, spec} =
             prepared_spec(ZaiCodingPlan,
               model: "glm-4.7",
               connection_options: %{"api_key" => "zai-key"},
               provider_options: %{"thinking" => %{"type" => "disabled"}},
               request: %{"input" => "hello"},
               stream?: true
             )

    assert spec.api_resolver == :openai_chat_completions
    assert spec.upstream.url == "https://api.z.ai/api/coding/paas/v4/chat/completions"
    assert headers(spec)["authorization"] == "Bearer zai-key"
    assert headers(spec)["user-agent"] == @zai_user_agent
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
               connection_options: %{"api_key" => "zai-key", "china_server" => true},
               provider_options: %{"thinking" => %{"type" => "enabled"}},
               request: %{"input" => "hello"}
             )

    assert spec.upstream.url == "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"
    assert headers(spec)["authorization"] == "Bearer zai-key"
    assert headers(spec)["user-agent"] == @zai_user_agent
    assert spec.response_context.provider_options == %{"thinking" => %{"type" => "enabled"}}
  end

  defp prepared_spec(module, opts) do
    definition = module.provider_definition()

    runtime = %{
      "provider_kind" => definition.provider_kind,
      "model" => Keyword.fetch!(opts, :model),
      "connection_options" => Keyword.get(opts, :connection_options, %{}),
      "provider_options" => Keyword.get(opts, :provider_options, %{})
    }

    with {:ok, ctx} <-
           PrepareContext.build(
             definition,
             :language_model,
             runtime,
             Keyword.fetch!(opts, :request),
             stream?: Keyword.get(opts, :stream?, false)
           ) do
      module
      |> apply(:prepare_language_model, [ctx])
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
