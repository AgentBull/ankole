defmodule Ankole.AIGateway.Providers.AgentBullCloud do
  @moduledoc """
  AgentBull Cloud meta-search provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 30_000

  provider :agentbull_cloud do
    label(%{"default" => "AgentBull Cloud", "zh-Hans-CN" => "AgentBull Cloud"})
    base_url("https://serp.yuma.host")

    setting(:api_key, encrypted: true)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)

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
    |> UniversalAIRequest.new("search", :agentbull_web_search, include_model: false)
    |> UniversalAIRequest.bearer_auth()
  end
end
