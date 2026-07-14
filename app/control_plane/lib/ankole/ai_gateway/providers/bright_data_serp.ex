defmodule Ankole.AIGateway.Providers.BrightDataSERP do
  @moduledoc """
  Bright Data SERP API search provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @timeout_ms 120_000

  provider :bright_data_serp do
    label(%{"default" => "Bright Data SERP", "zh-Hans-CN" => "Bright Data SERP"})
    base_url("https://api.brightdata.com", advanced: true)

    setting(:api_key, encrypted: true)
    setting(:zone, required: true)
    setting(:country)
    setting(:language)
    setting(:google_domain)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)

    setting(:country, scope: :request)
    setting(:language, scope: :request)
    setting(:google_domain, scope: :request)

    web_search do
      upstream(:json)
      api_resolver(:bright_data_serp_web_search)
      prepare(:prepare_web_search)
      timeout_ms(@timeout_ms)
    end
  end

  def prepare_web_search(ctx) do
    ctx
    |> UniversalAIRequest.new("request", :bright_data_serp_web_search, include_model: false)
    |> UniversalAIRequest.bearer_auth()
    |> UniversalAIRequest.put_provider_options(provider_options(ctx))
  end

  defp provider_options(ctx) do
    ctx.provider_options
    |> Map.put_new("zone", ctx.settings[:zone])
    |> Map.put_new("country", ctx.settings[:country])
    |> Map.put_new("language", ctx.settings[:language])
    |> Map.put_new("google_domain", ctx.settings[:google_domain])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end
end
