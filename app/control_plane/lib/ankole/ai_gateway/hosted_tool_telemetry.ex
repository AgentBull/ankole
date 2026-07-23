defmodule Ankole.AIGateway.HostedToolTelemetry do
  @moduledoc """
  Emits bounded hosted image-generation telemetry without public response data.

  Prompts, URLs, base64 payloads, file contents, and provider credentials are
  intentionally not accepted by this boundary.
  """

  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.OpenAIError

  @event [:ankole, :ai_gateway, :hosted_image_generation]
  @measurement_keys ~w(
    hosted_tool_calls successful_image_calls main_model_rounds image_latency_ms
    input_bytes output_bytes partial_images provider_cost
  )a

  @spec emit(map() | nil) :: :ok
  def emit(%{} = raw) do
    measurements =
      Map.new(@measurement_keys, fn key ->
        {key, number(raw, Atom.to_string(key))}
      end)
      |> Map.put(:count, 1)

    metadata = %{
      result: string(raw, "result") || "success",
      failure_reason: string(raw, "failure_reason"),
      model: string(raw, "model"),
      provider_tag: string(raw, "provider_tag"),
      provider_slug: string(raw, "provider_slug")
    }

    :telemetry.execute(@event, measurements, metadata)
  end

  def emit(_metadata), do: :ok

  @spec emit_summary(map() | nil) :: :ok
  def emit_summary(%{"hosted_tool_metadata" => %{} = metadata}), do: emit(metadata)
  def emit_summary(%{hosted_tool_metadata: %{} = metadata}), do: emit(metadata)
  def emit_summary(_summary), do: :ok

  @spec emit_failure(map() | nil, term()) :: :ok
  def emit_failure(spec, %{"hosted_tool_metadata" => %{} = metadata} = reason),
    do: emit_failure_log(spec, reason, metadata)

  def emit_failure(spec, %{hosted_tool_metadata: %{} = metadata} = reason),
    do: emit_failure_log(spec, reason, metadata)

  def emit_failure(spec, reason) do
    image_spec = hosted_image_spec(spec)

    metadata = %{
      "result" => "failure",
      "failure_reason" => failure_reason(reason),
      "model" => value(image_spec, "selected_model"),
      "provider_tag" => value(image_spec, "provider_tag"),
      "provider_slug" => value(image_spec, "provider_slug")
    }

    emit_failure_log(spec, reason, metadata)
  end

  defp emit_failure_log(spec, reason, metadata) do
    :ok = emit(metadata)

    FailureDiagnostics.log(
      "ai_gateway.hosted_image_generation_failed",
      "AIGateway hosted image generation failed",
      failure_log_context(spec, reason, metadata),
      reason
    )
  end

  defp hosted_image_spec(%{} = spec) do
    hosted_tools = Map.get(spec, :hosted_tools) || Map.get(spec, "hosted_tools") || %{}
    Map.get(hosted_tools, :image_generation) || Map.get(hosted_tools, "image_generation") || %{}
  end

  defp hosted_image_spec(_spec), do: %{}

  defp failure_reason(%OpenAIError{code: code}), do: code
  defp failure_reason(%{"code" => code}) when is_binary(code), do: code
  defp failure_reason(%{code: code}) when is_binary(code), do: code
  defp failure_reason({tag, _details}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_reason(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_reason(_reason), do: "unknown"

  defp failure_log_context(spec, reason, metadata) do
    image_spec = hosted_image_spec(spec)

    %{
      actor_event_id: string(image_spec, "actor_event_id"),
      failure_reason: string(metadata, "failure_reason") || failure_reason(reason),
      model: string(metadata, "model") || string(image_spec, "selected_model"),
      provider_tag: string(metadata, "provider_tag") || string(image_spec, "provider_tag"),
      provider_slug: string(metadata, "provider_slug") || string(image_spec, "provider_slug"),
      provider_tags: string_list(value(image_spec, "provider_tags")),
      provider_slugs: string_list(value(image_spec, "provider_slugs")),
      image_latency_ms: positive_number(metadata, "image_latency_ms")
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) or value == [] end)
  end

  defp string_list(values) when is_list(values) do
    Enum.filter(values, &(is_binary(&1) and &1 != ""))
  end

  defp string_list(_values), do: []

  defp positive_number(map, key) do
    case value(map, key) do
      value when (is_integer(value) or is_float(value)) and value > 0 -> value
      _value -> nil
    end
  end

  defp number(map, key) do
    case value(map, key) do
      value when is_integer(value) or is_float(value) -> value
      _value -> 0
    end
  end

  defp string(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        _entry ->
          nil
      end)
  end
end
