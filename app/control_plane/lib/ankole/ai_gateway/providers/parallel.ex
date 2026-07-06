defmodule Ankole.AIGateway.Providers.Parallel do
  @moduledoc """
  Parallel web search and fetch provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 120_000

  provider :parallel do
    label(%{"default" => "Parallel", "zh-Hans-CN" => "Parallel"})
    base_url("https://api.parallel.ai")

    setting(:api_key, encrypted: true)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)

    setting(:objective, scope: :request)
    setting(:search_queries, scope: :request)
    setting(:mode, scope: :request)
    setting(:max_chars_total, scope: :request)
    setting(:session_id, scope: :request)
    setting(:client_model, scope: :request)
    setting(:advanced_settings, type: :map, scope: :request)

    web_search do
      upstream(:json)
      api_resolver(:parallel_web_search)
      prepare(:prepare_web_search)
      timeout_ms(@timeout_ms)
    end

    web_fetch do
      upstream(:json)
      api_resolver(:parallel_web_fetch)
      prepare(:prepare_web_fetch)
      timeout_ms(@timeout_ms)
    end
  end

  def prepare_web_search(ctx) do
    ctx
    |> UniversalAIRequest.new("v1/search", :parallel_web_search, include_model: false)
    |> UniversalAIRequest.api_key_header("x-api-key")
  end

  def prepare_web_fetch(ctx) do
    ctx
    |> UniversalAIRequest.new("v1/extract", :parallel_web_fetch, include_model: false)
    |> UniversalAIRequest.api_key_header("x-api-key")
  end
end
