defmodule Ankole.AIGateway.Providers.Claude do
  @moduledoc """
  Anthropic Claude Messages provider.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @anthropic_version "2023-06-01"
  # Anthropic `output_config.effort` uses Ankole's public names from low through
  # max. The model metadata decides which of them each model accepts.
  @reasoning_effort_map Map.new(~w(low medium high xhigh max), &{&1, &1})
  # Fast mode on Claude Opus 5 and Opus 4.8 is a research preview that Anthropic
  # serves only with this beta flag.
  @fast_mode_beta "fast-mode-2026-02-01"

  provider :claude do
    label(%{"default" => "Claude", "zh-Hans-CN" => "Claude"})
    base_url("https://api.anthropic.com", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)

    setting(:auth_mode,
      type: :select,
      default: "api_key",
      options: ~w(api_key auth_token oauth),
      scope: :credential,
      advanced: true
    )

    setting(:headers, type: :map, advanced: true)
    setting(:anthropic_version, default: @anthropic_version, advanced: true)
    setting(:anthropic_beta, advanced: true)
    setting(:messages_path, default: "v1/messages", advanced: true)

    setting(:reasoningEffort,
      type: :select,
      options: ReasoningEffort.Levels.values(@reasoning_effort_map),
      scope: :request
    )

    setting(:speed, type: :select, options: ~w(fast), scope: :request, advanced: true)
    setting(:inferenceGeo, scope: :request, advanced: true)

    language_model do
      api_resolver(:anthropic_messages)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end
  end

  @doc "Returns the reasoning-effort target and value map of this provider's language-model requests."
  def reasoning_effort_options, do: [target: :output_config, map: @reasoning_effort_map]

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
    |> maybe_put_beta(anthropic_betas(ctx))
    |> put_auth(ctx)
    |> ReasoningEffort.put_provider_options(ctx, reasoning_effort_options())
    |> UniversalAIRequest.rename_provider_option("inferenceGeo", "inference_geo")
    |> put_default_cache_control(ctx)
  end

  # Anthropic Messages caches a prompt prefix only when `cache_control` is
  # supplied. Top-level ephemeral `cache_control` enables automatic prefix
  # caching across system instructions, tools, and conversation turns while
  # preserving any explicit caller breakpoint configuration.
  defp put_default_cache_control({:error, _reason} = error, _ctx), do: error

  defp put_default_cache_control(%UniversalAIRequest{} = request, ctx) do
    provider_options = request.provider_options || %{}

    cond do
      Map.has_key?(provider_options, "cache_control") ->
        request

      is_map(ctx.request) and Map.has_key?(ctx.request, "cache_control") ->
        request

      count_block_cache_controls(ctx.request) >= 4 ->
        request

      true ->
        UniversalAIRequest.put_provider_options(
          request,
          Map.put(provider_options, "cache_control", %{"type" => "ephemeral"})
        )
    end
  end

  defp count_block_cache_controls(%{} = value) do
    own = if Map.has_key?(value, "cache_control"), do: 1, else: 0

    nested =
      Enum.reduce(value, 0, fn
        {"cache_control", _v}, acc -> acc
        {_k, v}, acc -> acc + count_block_cache_controls(v)
      end)

    own + nested
  end

  defp count_block_cache_controls(values) when is_list(values),
    do: Enum.reduce(values, 0, fn v, acc -> acc + count_block_cache_controls(v) end)

  defp count_block_cache_controls(_value), do: 0

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
  defp maybe_put_beta(headers, []), do: headers

  defp maybe_put_beta(headers, values),
    do: UniversalAIRequest.put_header(headers, "anthropic-beta", Enum.join(values, ","))

  # The operator's own beta flags come first; a fast request adds the fast-mode
  # flag when the operator has not listed it.
  defp anthropic_betas(ctx) do
    configured = beta_list(ctx.settings[:anthropic_beta])
    options = Ankole.Attrs.normalize_external_attrs(ctx.provider_options || %{})

    if options["speed"] == "fast" and @fast_mode_beta not in configured,
      do: configured ++ [@fast_mode_beta],
      else: configured
  end

  defp beta_list(value) when is_binary(value),
    do:
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp beta_list(values) when is_list(values), do: Enum.flat_map(values, &beta_list/1)
  defp beta_list(_value), do: []
end
