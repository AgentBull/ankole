defmodule Ankole.Plugins.ChinaMarketAIProviders.Providers.XiaomiMiMo do
  @moduledoc """
  Xiaomi MiMo provider backed by its Anthropic-compatible Messages endpoint.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.UniversalAIRequest

  @anthropic_version "2023-06-01"
  @pay_as_you_go_base_url "https://api.xiaomimimo.com/anthropic"
  @token_plan_base_url "https://token-plan-cn.xiaomimimo.com/anthropic"

  provider "xiaomi_mimo" do
    label(%{"default" => "Xiaomi MiMo", "zh-Hans-CN" => "小米 MiMo"})
    base_url(@pay_as_you_go_base_url)

    setting(:api_key, encrypted: true)
    setting(:access_token, encrypted: true)
    setting(:auth_mode, default: "api_key")
    setting(:headers, type: :map)
    setting(:query_params, type: :map)
    setting(:anthropic_version, default: @anthropic_version)
    setting(:anthropic_beta)
    setting(:messages_path, default: "v1/messages")

    setting(:xiaomi_mimo_billing_plan, default: "pay_as_you_go", scope: :request)
    setting(:thinking, type: :map, scope: :request)
    setting(:stop_sequences, scope: :request)
    setting(:metadata, type: :map, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:anthropic_messages)
      prepare(:prepare_language_model)
    end
  end

  def prepare_language_model(ctx) do
    ctx = put_effective_base_url(ctx)

    ctx
    |> UniversalAIRequest.new(ctx.settings[:messages_path] || "v1/messages", :anthropic_messages)
    |> UniversalAIRequest.put_new_setting_header("anthropic-version", :anthropic_version)
    |> maybe_put_beta(ctx.settings[:anthropic_beta])
    |> put_auth(ctx)
    |> UniversalAIRequest.put_provider_options(provider_body_options(ctx))
  end

  @impl true
  def check_connection(ctx) when is_map(ctx) do
    ctx = put_effective_base_url(ctx)

    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.put_new_header(
        "anthropic-version",
        ctx.settings[:anthropic_version] || @anthropic_version
      )
      |> maybe_put_beta(ctx.settings[:anthropic_beta])
      |> put_auth(ctx)

    with {:ok, %{"status" => status, "body" => body}} when status in 200..299 <-
           UniversalAIRequest.raw_get(ctx, "v1/models", headers: headers) do
      {:ok, body}
    else
      {:ok, %{"status" => status, "body" => body}} ->
        {:error, {:provider_connection_check_failed, status, body}}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_effective_base_url(%{settings: settings} = ctx) when is_map(settings) do
    %{ctx | settings: Map.put(settings, :base_url, effective_base_url(settings))}
  end

  defp effective_base_url(settings) do
    base_url = settings[:base_url] |> to_string() |> String.trim_trailing("/")

    cond do
      custom_base_url?(base_url) ->
        base_url

      billing_plan(settings) == "token_plan" ->
        @token_plan_base_url

      true ->
        @pay_as_you_go_base_url
    end
  end

  defp custom_base_url?(""), do: false
  defp custom_base_url?(@pay_as_you_go_base_url), do: false
  defp custom_base_url?(@token_plan_base_url), do: false
  defp custom_base_url?(_base_url), do: true

  defp billing_plan(settings) do
    case settings[:xiaomi_mimo_billing_plan] || settings["xiaomi_mimo_billing_plan"] do
      value when value in ["token_plan", :token_plan] -> "token_plan"
      _value -> "pay_as_you_go"
    end
  end

  defp provider_body_options(ctx) do
    ctx.provider_options
    |> Map.delete("xiaomi_mimo_billing_plan")
    |> Map.delete(:xiaomi_mimo_billing_plan)
  end

  defp put_auth(request_or_headers, ctx) do
    case ctx.settings[:auth_mode] do
      mode when mode in ["auth_token", "oauth", :auth_token, :oauth] ->
        UniversalAIRequest.bearer_auth(
          request_or_headers,
          ctx.settings[:access_token] || ctx.settings[:api_key]
        )

      _mode ->
        UniversalAIRequest.api_key_header(request_or_headers, "x-api-key", ctx.settings[:api_key])
    end
  end

  defp maybe_put_beta(headers, value) when is_binary(value) and value != "",
    do: UniversalAIRequest.put_header(headers, "anthropic-beta", value)

  defp maybe_put_beta(headers, values) when is_list(values),
    do: UniversalAIRequest.put_header(headers, "anthropic-beta", Enum.join(values, ","))

  defp maybe_put_beta(headers, _value), do: headers
end
