defmodule Ankole.Observability.WorkerOTLP do
  @moduledoc false

  @protobuf :opentelemetry_exporter_trace_service_pb
  @request :export_trace_service_request

  @type attribute_patch :: %{put: %{String.t() => String.t()}, drop: [String.t()]}

  @spec map_span_attributes(binary(), (map() -> attribute_patch())) ::
          {:ok, binary()} | {:error, :invalid_otlp_payload}
  def map_span_attributes(payload, mapper) when is_binary(payload) and is_function(mapper, 1) do
    try do
      request = @protobuf.decode_msg(payload, @request)

      resource_spans =
        Enum.map(Map.get(request, :resource_spans, []), fn resource_span ->
          scope_spans =
            Enum.map(Map.get(resource_span, :scope_spans, []), fn scope_span ->
              spans =
                Enum.map(Map.get(scope_span, :spans, []), fn span ->
                  attributes = Map.get(span, :attributes, [])

                  Map.put(
                    span,
                    :attributes,
                    patch_attributes(attributes, mapper.(attribute_map(attributes)))
                  )
                end)

              Map.put(scope_span, :spans, spans)
            end)

          Map.put(resource_span, :scope_spans, scope_spans)
        end)

      request
      |> Map.put(:resource_spans, resource_spans)
      |> @protobuf.encode_msg(@request)
      |> then(&{:ok, &1})
    rescue
      _error -> {:error, :invalid_otlp_payload}
    catch
      _kind, _reason -> {:error, :invalid_otlp_payload}
    end
  end

  defp attribute_map(attributes) do
    Map.new(attributes, fn attribute ->
      {to_string(Map.get(attribute, :key, "")), attribute_value(attribute)}
    end)
  end

  defp attribute_value(%{value: %{value: {_type, value}}}), do: value
  defp attribute_value(_attribute), do: nil

  defp patch_attributes(attributes, %{put: put, drop: drop})
       when is_map(put) and is_list(drop) do
    replaced = Map.keys(put) ++ drop

    retained =
      Enum.reject(attributes, fn attribute ->
        to_string(Map.get(attribute, :key, "")) in replaced
      end)

    additions =
      put
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} ->
        %{key: key, value: %{value: {:string_value, value}}}
      end)

    retained ++ additions
  end
end
