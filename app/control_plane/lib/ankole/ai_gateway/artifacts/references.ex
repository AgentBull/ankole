defmodule Ankole.AIGateway.Artifacts.References do
  @moduledoc false

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Artifacts.Image
  alias Ankole.AIGateway.Artifacts.ReferenceBudget
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Schemas.Artifact

  @max_image_bytes 50 * 1024 * 1024

  @spec hydrate_generated_images(String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def hydrate_generated_images(subject_uid, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case hydrate_generated_image(subject_uid, item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, hydrated} -> {:ok, Enum.reverse(hydrated)}
      {:error, _reason} = error -> error
    end
  end

  @spec resolve(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def resolve(subject_uid, request) when is_map(request) do
    with :ok <- validate_reference_shapes(request) do
      request
      |> collect_reference_specs()
      |> Enum.reduce_while({:ok, [], 0}, fn reference, {:ok, acc, bytes} ->
        case resolve_reference(subject_uid, reference) do
          {:ok, resolved, size} ->
            resolved =
              if Map.get(reference, :mask?, false),
                do: Map.put(resolved, "mask", true),
                else: resolved

            case ReferenceBudget.consume(bytes, size) do
              {:ok, total} ->
                {:cont, {:ok, [resolved | acc], total}}

              {:error, :request_too_large} ->
                {:halt,
                 {:error,
                  OpenAIError.invalid(
                    "input",
                    "request_too_large",
                    "Referenced images exceed the 100 MiB request limit."
                  )}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, references, _bytes} -> {:ok, Enum.reverse(references)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp collect_reference_specs(request) do
    input_references(value(request, "input")) ++ mask_references(value(request, "tools") || [])
  end

  defp input_references(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> input_item_references(item, index) end)
  end

  defp input_references(_input), do: []

  defp input_item_references(%{"type" => "image_generation_call", "id" => id}, _index),
    do: [%{id: id, kind: :generated}]

  defp input_item_references(%{} = item, item_index) do
    case value(item, "content") do
      content when is_list(content) ->
        content
        |> Enum.with_index()
        |> Enum.flat_map(fn {part, part_index} ->
          input_part_references(part, "input[#{item_index}].content[#{part_index}]")
        end)

      _content ->
        []
    end
  end

  defp input_item_references(_item, _index), do: []

  defp input_part_references(%{} = part, path) do
    if value(part, "type") == "input_image" do
      cond do
        is_binary(value(part, "file_id")) ->
          [%{id: value(part, "file_id"), kind: :file}]

        is_binary(value(part, "image_url")) ->
          [%{id: path, kind: :url, url: value(part, "image_url")}]

        true ->
          []
      end
    else
      []
    end
  end

  defp input_part_references(_part, _path), do: []

  defp mask_references(tools) when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.flat_map(fn {tool, index} ->
      if value(tool, "type") == "image_generation" do
        case value(tool, "input_image_mask") do
          %{} = mask ->
            mask
            |> Map.put("type", "input_image")
            |> input_part_references("tools[#{index}].input_image_mask")
            |> Enum.map(&Map.put(&1, :mask?, true))

          _mask ->
            []
        end
      else
        []
      end
    end)
  end

  defp mask_references(_tools), do: []

  defp resolve_reference(_subject_uid, %{kind: :url, id: id, url: "data:" <> _rest = url}) do
    with {:ok, payload, declared_mime} <- decode_data_url(url, id),
         :ok <- validate_data_url_size(payload, id),
         {:ok, sniffed_mime} <- Image.sniff(payload),
         :ok <- Image.validate_declared_mime(declared_mime, sniffed_mime) do
      {:ok, %{"id" => id, "image_url" => url, "source" => "data_url"}, byte_size(payload)}
    end
  end

  defp resolve_reference(_subject_uid, %{kind: :url, id: id, url: url}) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %{"id" => id, "image_url" => url, "source" => "external"}, 0}

      _uri ->
        {:error,
         OpenAIError.invalid(
           id,
           "invalid_value",
           "image_url must be an HTTP(S) URL or an image data URL."
         )}
    end
  end

  defp resolve_reference(subject_uid, %{kind: :file, id: id}) do
    with {:ok, artifact} <- Artifacts.get_file(subject_uid, id, payload?: true) do
      {:ok, reference(artifact), artifact.byte_size}
    end
  end

  defp resolve_reference(subject_uid, %{kind: :generated, id: id}) do
    with {:ok, artifact} <- Artifacts.get_generated_image(subject_uid, id, payload?: true) do
      {:ok, reference(artifact), artifact.byte_size}
    end
  end

  defp reference(%Artifact{} = artifact) do
    %{
      "id" => Artifacts.public_id(artifact),
      "image_url" => "data:#{artifact.mime_type};base64,#{Base.encode64(artifact.payload)}",
      "source" => "artifact"
    }
  end

  defp hydrate_generated_image(
         subject_uid,
         %{"type" => "image_generation_call", "id" => id, "result" => nil} = item
       )
       when is_binary(id) do
    with {:ok, artifact} <- Artifacts.get_generated_image(subject_uid, id, payload?: true) do
      {:ok, Map.put(item, "result", Base.encode64(artifact.payload))}
    end
  end

  defp hydrate_generated_image(_subject_uid, item), do: {:ok, item}

  defp validate_reference_shapes(request) do
    request
    |> reference_shapes()
    |> Enum.reduce_while(:ok, fn {path, shape}, :ok ->
      case validate_reference_shape(path, shape) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reference_shapes(request) do
    input_shapes(value(request, "input")) ++ mask_shapes(value(request, "tools") || [])
  end

  defp input_shapes(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{} = item, index} -> item_shapes(item, "input[#{index}]")
      {_item, _index} -> []
    end)
  end

  defp input_shapes(_items), do: []

  defp item_shapes(%{"type" => "image_generation_call"} = item, path), do: [{path, item}]

  defp item_shapes(%{} = item, path) do
    case value(item, "content") do
      content when is_list(content) ->
        content
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%{} = part, index} ->
            if value(part, "type") == "input_image",
              do: [{"#{path}.content[#{index}]", part}],
              else: []

          {_part, _index} ->
            []
        end)

      _content ->
        []
    end
  end

  defp mask_shapes(tools) when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"type" => "image_generation", "input_image_mask" => %{} = mask}, index} ->
        [{"tools[#{index}].input_image_mask", Map.put(mask, "type", "input_image")}]

      {_tool, _index} ->
        []
    end)
  end

  defp mask_shapes(_tools), do: []

  defp validate_reference_shape(_path, %{"type" => "image_generation_call", "id" => id})
       when is_binary(id) and id != "",
       do: :ok

  defp validate_reference_shape(path, %{"type" => "image_generation_call"}) do
    {:error,
     OpenAIError.invalid("#{path}.id", "invalid_type", "image_generation_call.id is required.")}
  end

  defp validate_reference_shape(path, %{} = image) do
    file_id = value(image, "file_id")
    image_url = value(image, "image_url")

    cond do
      is_binary(file_id) and file_id != "" and is_nil(image_url) ->
        :ok

      is_binary(image_url) and image_url != "" and is_nil(file_id) ->
        :ok

      is_nil(file_id) and is_nil(image_url) ->
        {:error,
         OpenAIError.invalid(
           path,
           "missing_required_parameter",
           "An image reference requires exactly one of file_id or image_url."
         )}

      true ->
        {:error,
         OpenAIError.invalid(
           path,
           "invalid_value",
           "An image reference requires exactly one of file_id or image_url."
         )}
    end
  end

  defp decode_data_url(url, param) do
    case String.split(url, ",", parts: 2) do
      ["data:" <> metadata, encoded] ->
        case String.split(metadata, ";") do
          [mime_type, "base64"] when mime_type in ~w(image/png image/jpeg image/webp image/gif) ->
            case Base.decode64(encoded) do
              {:ok, payload} -> {:ok, payload, mime_type}
              :error -> invalid_data_url(param)
            end

          _metadata ->
            invalid_data_url(param)
        end

      _parts ->
        invalid_data_url(param)
    end
  end

  defp invalid_data_url(param) do
    {:error,
     OpenAIError.invalid(
       param,
       "invalid_value",
       "Image data URLs must contain a supported image MIME type and base64 payload."
     )}
  end

  defp validate_data_url_size(payload, _param) when byte_size(payload) <= @max_image_bytes,
    do: :ok

  defp validate_data_url_size(_payload, param) do
    {:error, OpenAIError.invalid(param, "request_too_large", "Image exceeds the 50 MiB limit.")}
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
