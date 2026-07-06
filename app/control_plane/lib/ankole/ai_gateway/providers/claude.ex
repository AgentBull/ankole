defmodule Ankole.AIGateway.Providers.Claude do
  @moduledoc """
  Anthropic Claude Messages provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @anthropic_version "2023-06-01"
  @reasoning_effort_map %{
    "none" => "none",
    "minimal" => "minimal",
    "low" => "low",
    "medium" => "medium",
    "high" => "high",
    "xhigh" => "max"
  }

  provider :claude do
    label(%{"default" => "Claude", "zh-Hans-CN" => "Claude"})
    base_url("https://api.anthropic.com")

    setting(:api_key, encrypted: true)
    setting(:auth_mode, default: "api_key")
    setting(:headers, type: :map)
    setting(:anthropic_version, default: @anthropic_version)
    setting(:anthropic_beta)
    setting(:messages_path, default: "v1/messages")

    setting(:reasoningEffort, scope: :request)
    setting(:thinking, scope: :request)
    setting(:cacheControl, scope: :request)
    setting(:structuredOutputMode, scope: :request)
    setting(:toolStreaming, scope: :request)
    setting(:effort, scope: :request)
    setting(:taskBudget, scope: :request)
    setting(:speed, scope: :request)
    setting(:inferenceGeo, scope: :request)
    setting(:anthropicBeta, scope: :request)
    setting(:contextManagement, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:anthropic_messages)
      prepare(:prepare_language_model)
    end
  end

  @doc """
  Builds an Anthropic Messages request.

  Anthropic keeps version and beta behavior in headers, so the provider adds
  those headers while the Rust `anthropic_messages` resolver owns stream
  normalization.
  """
  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new(ctx.settings[:messages_path] || "v1/messages", :anthropic_messages)
    |> UniversalAIRequest.put_new_setting_header("anthropic-version", :anthropic_version)
    |> maybe_put_beta(ctx.settings[:anthropic_beta])
    |> put_auth(ctx)
    |> ReasoningEffort.put_provider_options(ctx,
      target_key: "effort",
      map: @reasoning_effort_map,
      skip_if_present: ["thinking"]
    )
  end

  @doc """
  Prepares an Anthropic connection check using the same version/auth headers as model requests.
  """
  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> UniversalAIRequest.put_new_header(
        "anthropic-version",
        ctx.settings[:anthropic_version] || @anthropic_version
      )
      |> maybe_put_beta(ctx.settings[:anthropic_beta])
      |> put_auth(ctx)

    ProviderConnectionCheck.get(ctx, "v1/models", headers: headers)
  end

  # Anthropic-compatible gateways may accept OAuth-style bearer tokens, while
  # first-party Anthropic commonly uses `x-api-key`.
  defp put_auth(request, ctx) do
    credential = ctx.settings[:api_key]

    case ctx.settings[:auth_mode] do
      mode when mode in ["auth_token", "oauth", :auth_token, :oauth] ->
        UniversalAIRequest.bearer_auth(request, credential)

      _mode ->
        UniversalAIRequest.api_key_header(request, "x-api-key", credential)
    end
  end

  # Anthropic beta headers are comma-separated even when the Console stores them
  # as a list for easier editing.
  defp maybe_put_beta(headers, value) when is_binary(value) and value != "",
    do: UniversalAIRequest.put_header(headers, "anthropic-beta", value)

  defp maybe_put_beta(headers, values) when is_list(values),
    do: UniversalAIRequest.put_header(headers, "anthropic-beta", Enum.join(values, ","))

  defp maybe_put_beta(headers, _value), do: headers
end
