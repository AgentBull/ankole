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
  # OpenAI Chat Completions rejects these Responses request fields.
  @responses_only_options ~w(reasoningSummary truncation contextManagement)

  @type endpoint :: :responses | :chat_completions

  @doc "Returns the reasoning summary values accepted by OpenAI Responses."
  @spec reasoning_summary_values() :: [String.t()]
  def reasoning_summary_values, do: @reasoning_summary_values

  @doc "Returns the text verbosity values accepted by OpenAI."
  @spec text_verbosity_values() :: [String.t()]
  def text_verbosity_values, do: @text_verbosity_values

  @doc "Writes the public options to their provider-native request locations."
  @spec put_provider_options(UniversalAIRequest.t() | {:error, term()}, endpoint()) ::
          UniversalAIRequest.t() | {:error, term()}
  def put_provider_options({:error, _reason} = error, _endpoint), do: error

  def put_provider_options(%UniversalAIRequest{} = request, :responses) do
    options =
      (request.provider_options || %{})
      |> put_nested_option("reasoningSummary", "reasoning", "summary")
      |> put_nested_option("textVerbosity", "text", "verbosity")
      |> rename_common_options()
      |> rename_option("contextManagement", "context_management")

    UniversalAIRequest.put_provider_options(request, options)
  end

  def put_provider_options(%UniversalAIRequest{} = request, :chat_completions) do
    options = request.provider_options || %{}

    case Enum.find(@responses_only_options, &Map.has_key?(options, &1)) do
      nil ->
        UniversalAIRequest.put_provider_options(
          request,
          options
          |> rename_option("textVerbosity", "verbosity")
          |> rename_common_options()
        )

      option ->
        {:error, {:unsupported_provider_option, option, "chat_completions"}}
    end
  end

  # Both OpenAI wires accept these fields under their snake_case names.
  defp rename_common_options(options) do
    options
    |> rename_option("serviceTier", "service_tier")
    |> rename_option("promptCacheKey", "prompt_cache_key")
    |> rename_option("promptCacheRetention", "prompt_cache_retention")
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
