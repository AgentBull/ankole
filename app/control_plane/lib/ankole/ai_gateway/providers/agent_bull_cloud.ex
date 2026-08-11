defmodule Ankole.AIGateway.Providers.AgentBullCloud do
  @moduledoc """
  AgentBull Cloud meta-search provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 120_000

  provider :agentbull_cloud do
    label(%{"default" => "AgentBull Cloud", "zh-Hans-CN" => "AgentBull Cloud"})
    base_url("https://cloudapis.agentbull.com")

    setting(:api_key, encrypted: true, required: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:sources, scope: :request)
    setting(:timeRange, scope: :request)
    setting(:skip_cache, scope: :request)

    web_search do
      upstream(:json)
      api_resolver(:agentbull_web_search)
      prepare(:prepare_web_search)
      timeout_ms(@timeout_ms)
    end
  end

  def prepare_web_search(ctx) do
    ctx
    |> UniversalAIRequest.new("web-search/v1/search", :agentbull_web_search, include_model: false)
    |> UniversalAIRequest.bearer_auth()
  end
end
