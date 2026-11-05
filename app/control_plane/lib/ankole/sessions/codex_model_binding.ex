defmodule Ankole.Sessions.CodexModelBinding do
  @moduledoc false

  @header_name "x-ankole-aigateway-model-binding"
  require Ankole.ModelIntegerID
  alias Ankole.AIGateway.ChatGPTProtocol

  @spec header_name() :: String.t()
  def header_name, do: @header_name

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
         {:ok, job} <- decode_job(Map.get(binding, "job")) do
      decoded = %{
        "selector" => selector,
        "provider_options" => provider_options,
        "supports_parallel_tool_calls" => supports_parallel_tool_calls,
        "input_modalities" => input_modalities
      }

      {:ok,
       decoded
       |> Ankole.Attrs.maybe_put("vision_fallback", vision_fallback)
       |> Ankole.Attrs.maybe_put("job", job)}
    else
      _value -> {:error, :invalid_codex_model_binding}
    end
  end

  def decode(_encoded), do: {:error, :invalid_codex_model_binding}

  @doc """
  Adds the Job attempt that the binding names to the gateway request context.

  A Codex Job composes its own requests, so the Worker's frozen binding is the
  only carrier of the Job identity. The usage ledger and the traces read
  `job_id`, `attempts`, `signal_id`, `session_id`, and `human_uid` from the
  request context under the same keys that a Session Turn writes. The Worker
  freezes `human_uid` from the attempt's turn context at admission.
  """
  @spec request_context(map() | nil, map()) :: map()
  def request_context(
        %{"job" => %{"id" => id, "attempt" => attempt, "signal_id" => signal_id} = job},
        request_context
      )
      when is_map(request_context) do
    request_context
    |> Map.merge(%{
      "job_id" => id,
      "attempts" => attempt,
      "signal_id" => signal_id,
      "session_id" => Ankole.BackgroundAgentJobs.job_session_id(id)
    })
    |> Ankole.Attrs.maybe_put("human_uid", job["human_uid"])
  end

  def request_context(_binding, request_context) when is_map(request_context),
    do: request_context

  # The Worker names the Job attempt that composes the requests, so each
  # provider round can be attributed to one Job and the Human it serves.
  defp decode_job(nil), do: {:ok, nil}

  defp decode_job(%{"id" => id, "attempt" => attempt, "signal_id" => signal_id} = job)
       when is_integer(attempt) and attempt >= 0 and is_binary(signal_id) do
    with true <- Ankole.ModelIntegerID.valid?(id),
         {:ok, signal_id} <- Ecto.UUID.cast(signal_id),
         {:ok, human_uid} <- decode_human_uid(Map.get(job, "human_uid")) do
      {:ok,
       Ankole.Attrs.maybe_put(
         %{"id" => id, "attempt" => attempt, "signal_id" => signal_id},
         "human_uid",
         human_uid
       )}
    else
      _invalid -> {:error, :invalid_codex_model_binding}
    end
  end

  defp decode_job(_value), do: {:error, :invalid_codex_model_binding}

  defp decode_human_uid(nil), do: {:ok, nil}

  defp decode_human_uid(uid) when is_binary(uid) do
    case Ankole.Ecto.PrincipalKey.cast(uid) do
      {:ok, uid} when is_binary(uid) -> {:ok, uid}
      _invalid -> :error
    end
  end

  defp decode_human_uid(_uid), do: :error

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
