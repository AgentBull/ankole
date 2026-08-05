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

    UniversalAIRequest.put_provider_options(request, options)
  end

  def put_provider_options(%UniversalAIRequest{} = request, :chat_completions) do
    case Map.pop(request.provider_options || %{}, "reasoningSummary") do
      {nil, options} ->
        UniversalAIRequest.put_provider_options(
          request,
          rename_option(options, "textVerbosity", "verbosity")
        )

      {_value, _options} ->
        {:error, {:unsupported_provider_option, "reasoningSummary", "chat_completions"}}
    end
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
