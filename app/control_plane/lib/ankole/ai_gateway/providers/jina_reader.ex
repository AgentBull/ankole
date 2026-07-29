defmodule Ankole.AIGateway.Providers.JinaReader do
  @moduledoc """
  Jina Reader web fetch provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 120_000

  provider :jina_reader do
    label(%{"default" => "Jina Reader", "zh-Hans-CN" => "Jina Reader"})
    base_url("https://r.jina.ai", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:respondWith, scope: :request)
    setting(:retainLinks, scope: :request)
    setting(:noCache, scope: :request)
    setting(:timeout, scope: :request)
    setting(:targetSelector, scope: :request)
    setting(:waitForSelector, scope: :request)
    setting(:removeSelector, scope: :request)
    setting(:engine, scope: :request)
    setting(:maxTokens, scope: :request)

    web_fetch do
      upstream(:json)
      api_resolver(:jina_reader_web_fetch)
      prepare(:prepare_web_fetch)
      timeout_ms(@timeout_ms)
    end
  end

  def prepare_web_fetch(ctx) do
    ctx
    |> UniversalAIRequest.new("/", :jina_reader_web_fetch, include_model: false)
    |> UniversalAIRequest.put_new_header("accept", "application/json")
    |> UniversalAIRequest.put_new_header("x-respond-with", "markdown")
    |> UniversalAIRequest.bearer_auth()
  end
end
