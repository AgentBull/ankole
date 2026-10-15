defmodule Ankole.Sessions.CodexModelBinding do
  @moduledoc false

  @header_name "x-ankole-aigateway-model-binding"
  alias Ankole.AIGateway.ChatGPTProtocol

  @spec header_name() :: String.t()
  def header_name, do: @header_name

  @doc "Builds the trusted memory context at the runtime client's transport edge."
  def brain_context(_subject_uid, nil), do: {:ok, nil}

  def brain_context(subject_uid, %{"brain" => %{"signal_id" => signal_id}}) do
    Ankole.Brain.RequestContext.build(subject_uid, %{"signal_id" => signal_id})
  end

  def brain_context(_subject_uid, _binding), do: {:ok, nil}

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
         {:ok, vision_fallback} <- decode_vision_fallback(Map.get(binding, "vision_fallback")),
         {:ok, brain} <- decode_brain(Map.get(binding, "brain")) do
      decoded = %{
        "selector" => selector,
        "provider_options" => provider_options,
        "supports_parallel_tool_calls" => supports_parallel_tool_calls,
        "input_modalities" => input_modalities
      }

      {:ok,
       decoded
       |> Ankole.Attrs.maybe_put("vision_fallback", vision_fallback)
       |> Ankole.Attrs.maybe_put("brain", brain)}
    else
      _value -> {:error, :invalid_codex_model_binding}
    end
  end

  def decode(_encoded), do: {:error, :invalid_codex_model_binding}

  @spec apply(map(), map() | nil, map()) :: map()
  def apply(request, binding, request_context \\ %{})

  def apply(request, nil, _request_context) when is_map(request), do: request

  def apply(request, binding, request_context)
      when is_map(request) and is_map(binding) and is_map(request_context) do
    defaults = Map.fetch!(binding, "provider_options")

    responses_lite? = ChatGPTProtocol.lite_request?(request, request_context)

    request
    |> strip_codex_private_input_fields()
    |> Map.put("model", Map.fetch!(binding, "selector"))
    |> put_provider_options(defaults)
    |> put_reasoning_effort(defaults)
    |> put_brain(Map.get(binding, "brain"))
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

  # A codex Job composes its own Responses requests, so the Worker's frozen
  # binding carries the hosted Brain declaration the Job may use and the actor
  # event that scopes it. Jobs declare the read-only subset.
  defp decode_brain(nil), do: {:ok, nil}

  defp decode_brain(%{"operations" => operations, "signal_id" => signal_id})
       when is_list(operations) and operations != [] and is_binary(signal_id) and
              signal_id != "" do
    if Enum.all?(operations, &Ankole.Brain.Tools.operation?/1) and
         operations == Enum.uniq(operations) do
      {:ok, %{"operations" => operations, "signal_id" => signal_id}}
    else
      {:error, :invalid_codex_model_binding}
    end
  end

  defp decode_brain(_value), do: {:error, :invalid_codex_model_binding}

  defp put_brain(request, nil), do: request

  defp put_brain(request, %{"operations" => operations, "signal_id" => signal_id}) do
    tools =
      case Map.get(request, "tools") do
        tools when is_list(tools) -> tools
        _missing -> []
      end

    metadata =
      case Map.get(request, "metadata") do
        %{} = metadata -> metadata
        _missing -> %{}
      end

    request
    |> Map.put("tools", tools ++ [%{"type" => "brain", "operations" => operations}])
    |> Map.put("metadata", Map.put(metadata, "signal_id", signal_id))
  end

  defp strip_codex_private_input_fields(%{"input" => input} = request) when is_list(input) do
    input =
      Enum.map(input, fn
        %{} = item ->
          Map.drop(item, [
            "internal_chat_message_metadata_passthrough",
            "encrypted_function_args"
          ])

        item ->
          item
      end)

    Map.put(request, "input", input)
  end

  defp strip_codex_private_input_fields(request), do: request

  defp decode_modalities(modalities) when is_list(modalities) do
    if modalities != [] and Enum.all?(modalities, &(is_binary(&1) and &1 != "")) do
      {:ok, Enum.uniq(modalities)}
    else
      {:error, :invalid_codex_model_binding}
    end
  end

  defp decode_modalities(_value), do: {:error, :invalid_codex_model_binding}

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
