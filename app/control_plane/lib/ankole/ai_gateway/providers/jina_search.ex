defmodule Ankole.AIGateway.Providers.JinaSearch do
  @moduledoc """
  Jina Search web search provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 120_000

  provider :jina_search do
    label(%{"default" => "Jina Search", "zh-Hans-CN" => "Jina Search"})
    base_url("https://s.jina.ai", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:gl, scope: :request, advanced: true)
    setting(:location, scope: :request, advanced: true)
    setting(:hl, scope: :request, advanced: true)
    setting(:page, scope: :request, advanced: true)
    setting(:noCache, scope: :request, advanced: true)
    setting(:respondWith, scope: :request, advanced: true)
    setting(:engine, scope: :request, advanced: true)

    web_search do
      api_resolver(:jina_search_web_search)
      prepare(:prepare_web_search)
      timeout_ms(@timeout_ms)
    end
  end

  def prepare_web_search(ctx) do
    ctx
    |> UniversalAIRequest.new("search", :jina_search_web_search, include_model: false)
    |> UniversalAIRequest.put_new_header("accept", "application/json")
    |> UniversalAIRequest.put_new_header("content-type", "application/json")
    |> UniversalAIRequest.bearer_auth()
  end
end
