defmodule Ankole.AIGateway.CodexModelBinding do
  @moduledoc false

  @header_name "x-ankole-aigateway-model-binding"
  @responses_lite_header_name "x-openai-internal-codex-responses-lite"
  @responses_lite_client_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"

  @spec header_name() :: String.t()
  def header_name, do: @header_name

  @spec responses_lite_header_name() :: String.t()
  def responses_lite_header_name, do: @responses_lite_header_name

  @spec decode(String.t()) :: {:ok, map()} | {:error, :invalid_codex_model_binding}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, binding} <- Ankole.JSON.decode(json),
         %{
           "selector" => selector,
           "provider_options" => provider_options,
           "supports_parallel_tool_calls" => supports_parallel_tool_calls,
           "input_modalities" => input_modalities
         } <- binding,
         true <- is_binary(selector) and selector != "",
         true <- is_map(provider_options),
         true <- is_boolean(supports_parallel_tool_calls),
         {:ok, input_modalities} <- decode_modalities(input_modalities),
         {:ok, vision_fallback} <- decode_vision_fallback(Map.get(binding, "vision_fallback")) do
      decoded = %{
        "selector" => selector,
        "provider_options" => provider_options,
        "supports_parallel_tool_calls" => supports_parallel_tool_calls,
        "input_modalities" => input_modalities
      }

      {:ok, maybe_put(decoded, "vision_fallback", vision_fallback)}
    else
      _value -> {:error, :invalid_codex_model_binding}
    end
  end

  def decode(_encoded), do: {:error, :invalid_codex_model_binding}

  @spec apply(map(), map() | nil, keyword()) :: map()
  def apply(request, binding, opts \\ [])

  def apply(request, nil, _opts) when is_map(request), do: request

  def apply(request, binding, opts) when is_map(request) and is_map(binding) do
    defaults = Map.fetch!(binding, "provider_options")

    responses_lite? =
      Keyword.get_lazy(opts, :responses_lite?, fn -> responses_lite_request?(request) end)

    request
    |> Map.put("model", Map.fetch!(binding, "selector"))
    |> put_provider_options(defaults)
    |> put_reasoning_effort(defaults)
    |> Map.put("__ankole_codex_vision", %{
      "input_modalities" => Map.fetch!(binding, "input_modalities"),
      "vision_fallback" => Map.get(binding, "vision_fallback")
    })
    |> Map.put(
      "parallel_tool_calls",
      Map.fetch!(binding, "supports_parallel_tool_calls") and not responses_lite?
    )
  end

  defp decode_vision_fallback(nil), do: {:ok, nil}

  defp decode_vision_fallback(%{
         "selector" => selector,
         "provider_options" => provider_options,
         "input_modalities" => input_modalities
       })
       when is_binary(selector) and selector != "" and is_map(provider_options) do
    with {:ok, input_modalities} <- decode_modalities(input_modalities),
         true <- "image" in input_modalities do
      {:ok,
       %{
         "selector" => selector,
         "provider_options" => provider_options,
         "input_modalities" => input_modalities
       }}
    else
      _value -> {:error, :invalid_codex_model_binding}
    end
  end

  defp decode_vision_fallback(_value), do: {:error, :invalid_codex_model_binding}

  defp decode_modalities(modalities) when is_list(modalities) do
    if modalities != [] and Enum.all?(modalities, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(modalities)}
    else
      {:error, :invalid_codex_model_binding}
    end
  end

  defp decode_modalities(_value), do: {:error, :invalid_codex_model_binding}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp responses_lite_request?(request) do
    case Map.get(request, "client_metadata") do
      metadata when is_map(metadata) ->
        Map.get(metadata, @responses_lite_client_metadata_key) == "true"

      _value ->
        false
    end
  end

  defp put_provider_options(request, defaults) do
    case Map.get(request, "provider_options") do
      nil ->
        Map.put(request, "provider_options", defaults)

      overrides when is_map(overrides) ->
        Map.put(request, "provider_options", Map.merge(overrides, defaults))

      _invalid ->
        request
    end
  end

  defp put_reasoning_effort(request, defaults) do
    case Map.get(defaults, "reasoningEffort") do
      effort when is_binary(effort) and effort != "" ->
        reasoning =
          case Map.get(request, "reasoning") do
            %{} = current -> Map.put(current, "effort", effort)
            _value -> %{"effort" => effort}
          end

        Map.put(request, "reasoning", reasoning)

      _value ->
        request
    end
  end
end
