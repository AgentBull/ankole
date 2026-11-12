defmodule Ankole.AIGateway.OpenAIRequestOptions do
  @moduledoc """
  Maps Ankole's public OpenAI request options to the selected upstream API.

  ProviderDSL exposes stable camelCase option names to model profiles. OpenAI
  Responses and Chat Completions use different wire shapes, so this module
  keeps that protocol choice out of the Console and provider forms.
  """

  alias Ankole.AIGateway.UniversalAIRequest

  @reasoning_summary_values ~w(auto concise detailed)
  @text_verbosity_values ~w(low medium high)
  @truncation_values ~w(auto disabled)
  @prompt_cache_retention_values ~w(in_memory 24h)
  # Ankole suggests the tier names that Codex shows. OpenAI calls the fast tier
  # `priority`, and Azure serves an unknown tier at the default tier without
  # saying so. A custom tier passes through unchanged.
  @service_tier_wire_values %{"fast" => "priority", "flex" => "flex"}
  # OpenAI Chat Completions rejects these Responses request fields.
  @responses_only_options ~w(reasoningSummary truncation contextManagement)
  @decisions_unsupported_options ~w(
    reasoningEffort reasoningSummary serviceTier textVerbosity truncation contextManagement
    promptCacheRetention
  )

  @type endpoint :: :responses | :chat_completions | :decisions

  @doc "Returns the reasoning summary values accepted by OpenAI Responses."
  @spec reasoning_summary_values() :: [String.t()]
  def reasoning_summary_values, do: @reasoning_summary_values

  @doc "Returns the text verbosity values accepted by OpenAI."
  @spec text_verbosity_values() :: [String.t()]
  def text_verbosity_values, do: @text_verbosity_values

  @doc "Returns the truncation values accepted by OpenAI Responses."
  @spec truncation_values() :: [String.t()]
  def truncation_values, do: @truncation_values

  @doc "Returns the prompt-cache retention values accepted by OpenAI."
  @spec prompt_cache_retention_values() :: [String.t()]
  def prompt_cache_retention_values, do: @prompt_cache_retention_values

  @doc "Returns the service tier names that Console suggests."
  @spec service_tier_values() :: [String.t()]
  def service_tier_values, do: @service_tier_wire_values |> Map.keys() |> Enum.sort()

  @doc """
  Moves the public `serviceTier` option to OpenAI's `service_tier` field and
  value.
  """
  @spec put_service_tier(map()) :: map()
  def put_service_tier(options) when is_map(options) do
    case Map.pop(options, "serviceTier") do
      {nil, options} ->
        options

      {tier, options} ->
        Map.put(options, "service_tier", Map.get(@service_tier_wire_values, tier, tier))
    end
  end

  @doc "Writes the public options to their provider-native request locations."
  @spec put_provider_options(UniversalAIRequest.t() | {:error, term()}, endpoint(), map()) ::
          UniversalAIRequest.t() | {:error, term()}
  def put_provider_options(request, endpoint, raw_request \\ %{})

  def put_provider_options({:error, _reason} = error, _endpoint, _raw_request), do: error

  def put_provider_options(%UniversalAIRequest{} = request, :responses, _raw_request) do
    options =
      (request.provider_options || %{})
      |> put_nested_option("reasoningSummary", "reasoning", "summary")
      |> put_nested_option("textVerbosity", "text", "verbosity")
      |> rename_common_options()
      |> rename_option("contextManagement", "context_management")

    UniversalAIRequest.put_provider_options(request, options)
  end

  def put_provider_options(%UniversalAIRequest{} = request, :chat_completions, raw_request) do
    options = request.provider_options || %{}

    case Enum.find(@responses_only_options, &Map.has_key?(options, &1)) do
      nil ->
        UniversalAIRequest.put_provider_options(
          request,
          options
          |> rename_option("textVerbosity", "verbosity")
          |> rename_common_options()
          |> maybe_put_request_prompt_cache_key(raw_request)
        )

      option ->
        {:error, {:unsupported_provider_option, option, "chat_completions"}}
    end
  end

  def put_provider_options(%UniversalAIRequest{} = request, :decisions, _raw_request) do
    options = request.provider_options || %{}

    case Enum.find(@decisions_unsupported_options, &Map.has_key?(options, &1)) do
      nil ->
        UniversalAIRequest.put_provider_options(request, rename_common_options(options))

      option ->
        {:error, {:unsupported_provider_option, option, "decisions"}}
    end
  end

  defp maybe_put_request_prompt_cache_key(options, %{"prompt_cache_key" => key})
       when is_binary(key) and key != "" do
    Map.put_new(options, "prompt_cache_key", key)
  end

  defp maybe_put_request_prompt_cache_key(options, _raw_request), do: options

  # OpenAI endpoints accept these shared request fields under their snake_case names.
  defp rename_common_options(options) do
    options
    |> put_service_tier()
    |> rename_option("promptCacheKey", "prompt_cache_key")
    |> rename_option("promptCacheOptions", "prompt_cache_options")
    |> rename_option("promptCacheRetention", "prompt_cache_retention")
    |> rename_option("safetyIdentifier", "safety_identifier")
  end

  defp put_nested_option(options, public_key, object_key, native_key) do
    case Map.pop(options, public_key) do
      {nil, options} ->
        options

      {value, options} ->
        nested =
          case Map.get(options, object_key) do
            nested when is_map(nested) -> Map.put(nested, native_key, value)
            _value -> %{native_key => value}
          end

        Map.put(options, object_key, nested)
    end
  end

  defp rename_option(options, public_key, native_key) do
    case Map.pop(options, public_key) do
      {nil, options} -> options
      {value, options} -> Map.put(options, native_key, value)
    end
  end
end
