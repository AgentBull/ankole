defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.AlibabaCN do
  @moduledoc """
  Alibaba Cloud Bailian / DashScope provider for the mainland China endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.UniversalAIRequest

  provider "alibaba_cn" do
    label(%{"default" => "Alibaba Cloud DashScope CN", "zh-Hans-CN" => "阿里云百炼中国区"})
    base_url("https://dashscope.aliyuncs.com/compatible-mode/v1")

    setting(:api_key, encrypted: true)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)

    setting(:user, scope: :request)
    setting(:response_format, scope: :request)
    setting(:enable_search, type: :boolean, scope: :request)
    setting(:search_options, type: :map, scope: :request)
    setting(:enable_thinking, type: :boolean, scope: :request)
    setting(:thinking_budget, type: :integer, scope: :request)
    setting(:repetition_penalty, type: :float, scope: :request)
    setting(:enable_code_interpreter, type: :boolean, scope: :request)
    setting(:vl_high_resolution_images, type: :boolean, scope: :request)
    setting(:incremental_output, type: :boolean, scope: :request)
    setting(:top_k, type: :integer, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
    end
  end

  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> UniversalAIRequest.bearer_auth()
  end

  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    ProviderConnectionCheck.get(ctx, "models", headers: headers)
  end
end
