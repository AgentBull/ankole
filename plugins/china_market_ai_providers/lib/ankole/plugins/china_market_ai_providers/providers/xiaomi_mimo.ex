defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.XiaomiMiMo do
  @moduledoc """
  Xiaomi MiMo provider backed by its Anthropic-compatible Messages endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @pay_as_you_go_base_url "https://api.xiaomimimo.com/anthropic"
  # Token Plan serves each subscription from the cluster its console names, and
  # a Token Plan key does not work on the pay-as-you-go host.
  @token_plan_base_urls %{
    "token_plan" => "https://token-plan-cn.xiaomimimo.com/anthropic",
    "token_plan_sgp" => "https://token-plan-sgp.xiaomimimo.com/anthropic",
    "token_plan_ams" => "https://token-plan-ams.xiaomimimo.com/anthropic"
  }

  provider "xiaomi_mimo" do
    label(%{"default" => "Xiaomi MiMo", "zh-Hans-CN" => "小米 MiMo"})
    base_url(@pay_as_you_go_base_url, advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:access_token, encrypted: true, scope: :credential, advanced: true)

    setting(:auth_mode,
      type: :select,
      default: "api_key",
      options: ~w(api_key auth_token oauth),
      scope: :credential,
      advanced: true
    )

    setting(:xiaomi_mimo_billing_plan,
      type: :select,
      default: "pay_as_you_go",
      options: ["pay_as_you_go" | Map.keys(@token_plan_base_urls)]
    )

    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)
    setting(:thinking, type: :map, scope: :request, advanced: true)
    setting(:stop_sequences, scope: :request, advanced: true)
    setting(:metadata, type: :map, scope: :request, advanced: true)

    language_model do
      api_resolver(:anthropic_messages)
      prepare(:prepare_language_model)
    end
  end

  def prepare_language_model(ctx) do
    ctx = put_effective_base_url(ctx)

    ctx
    |> UniversalAIRequest.new("v1/messages", :anthropic_messages)
    |> put_auth(ctx)
    |> UniversalAIRequest.put_provider_options(ctx.provider_options)
  end

  defp put_effective_base_url(%{settings: settings} = ctx) when is_map(settings) do
    %{ctx | settings: Map.put(settings, :base_url, effective_base_url(settings))}
  end

  # A stored Xiaomi host is the Console's former default rather than a custom
  # endpoint, so the billing plan still chooses among the official hosts.
  defp effective_base_url(settings) do
    base_url = settings[:base_url] |> to_string() |> String.trim_trailing("/")

    if base_url == "" or official_base_url?(base_url) do
      Map.get(
        @token_plan_base_urls,
        to_string(settings[:xiaomi_mimo_billing_plan]),
        @pay_as_you_go_base_url
      )
    else
      base_url
    end
  end

  defp official_base_url?(base_url),
    do: base_url == @pay_as_you_go_base_url or base_url in Map.values(@token_plan_base_urls)

  # Xiaomi accepts the same key in either the `api-key` or the bearer header.
  defp put_auth(request_or_headers, ctx) do
    case ctx.settings[:auth_mode] do
      mode when mode in ["auth_token", "oauth", :auth_token, :oauth] ->
        UniversalAIRequest.bearer_auth(
          request_or_headers,
          ctx.settings[:access_token] || ctx.settings[:api_key]
        )

      _mode ->
        UniversalAIRequest.api_key_header(request_or_headers, "api-key", ctx.settings[:api_key])
    end
  end
end
