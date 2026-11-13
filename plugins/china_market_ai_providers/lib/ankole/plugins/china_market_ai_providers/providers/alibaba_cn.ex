defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.AlibabaCN do
  @moduledoc """
  Alibaba Cloud Bailian / DashScope provider for the mainland China endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  provider "alibaba_cn" do
    label(%{"default" => "Alibaba Cloud DashScope CN", "zh-Hans-CN" => "阿里云百炼中国区"})
    base_url("https://dashscope.aliyuncs.com/compatible-mode/v1", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:user, scope: :request, advanced: true)
    setting(:response_format, scope: :request, advanced: true)
    setting(:enable_search, type: :boolean, scope: :request, advanced: true)
    setting(:search_options, type: :map, scope: :request, advanced: true)
    setting(:enable_thinking, type: :boolean, scope: :request, advanced: true)
    setting(:thinking_budget, type: :integer, scope: :request, advanced: true)
    setting(:repetition_penalty, type: :float, scope: :request, advanced: true)
    setting(:enable_code_interpreter, type: :boolean, scope: :request, advanced: true)
    setting(:vl_high_resolution_images, type: :boolean, scope: :request, advanced: true)
    setting(:incremental_output, type: :boolean, scope: :request, advanced: true)
    setting(:top_k, type: :integer, scope: :request, advanced: true)

    language_model do
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
    end
  end

  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> UniversalAIRequest.bearer_auth()
  end
end
