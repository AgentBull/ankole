defmodule Ankole.AIGateway.Artifacts.References do
  @moduledoc false

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Artifacts.Image
  alias Ankole.AIGateway.Artifacts.ReferenceBudget
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Schemas.Artifact
  alias Ankole.Ecto.UUIDv7

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

  defp hydrate_generated_images(subject_uid, items, bytes) do
    Enum.reduce_while(items, {:ok, [], bytes}, fn item, {:ok, acc, bytes} ->
      case hydrate_generated_image(subject_uid, item, bytes) do
        {:ok, item, bytes} -> {:cont, {:ok, [item | acc], bytes}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, hydrated, bytes} -> {:ok, Enum.reverse(hydrated), bytes}
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

            case consume_reference_bytes(bytes, size) do
              {:ok, total} ->
                {:cont, {:ok, [resolved | acc], total}}

              {:error, _reason} = error ->
                {:halt, error}
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

  @doc """
  Rewrites local image references in `input` and image masks for a native-image
  dispatch.

  A native provider cannot read Ankole artifact ids, so a local `file_` or
  `ig_` reference in an `input_image` part becomes an inline data URL, and a
  replayed `image_generation_call` gets its stored result back. A reference
  the provider owns (its own file id, an HTTP URL, or a data URL) passes
  through unchanged.
  """
  @spec resolve_native_input(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_native_input(subject_uid, request) when is_map(request) do
    with {:ok, request, bytes} <- resolve_native_items(subject_uid, request, 0),
         {:ok, request, _bytes} <- inline_local_image_masks(subject_uid, request, bytes) do
      {:ok, request}
    end
  end

  defp resolve_native_items(subject_uid, request, bytes) do
    case Map.get(request, "input") do
      items when is_list(items) ->
        with {:ok, items, bytes} <- hydrate_generated_images(subject_uid, items, bytes),
             {:ok, items, bytes} <- inline_local_image_parts(subject_uid, items, bytes) do
          {:ok, Map.put(request, "input", items), bytes}
        end

      _input ->
        {:ok, request, bytes}
    end
  end

  defp inline_local_image_masks(_subject_uid, %{"max_tool_calls" => 0} = request, bytes),
    do: {:ok, request, bytes}

  defp inline_local_image_masks(subject_uid, request, bytes) do
    case Map.get(request, "tools") do
      tools when is_list(tools) ->
        tools
        |> Enum.reduce_while({:ok, [], bytes}, fn tool, {:ok, acc, bytes} ->
          case inline_local_image_mask(subject_uid, tool, bytes) do
            {:ok, tool, bytes} -> {:cont, {:ok, [tool | acc], bytes}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, tools, bytes} ->
            {:ok, Map.put(request, "tools", Enum.reverse(tools)), bytes}

          {:error, _reason} = error ->
            error
        end

      _tools ->
        {:ok, request, bytes}
    end
  end

  defp inline_local_image_mask(
         subject_uid,
         %{"type" => "image_generation", "input_image_mask" => %{} = mask} = tool,
         bytes
       ) do
    with {:ok, mask, bytes} <-
           inline_local_image_part(
             subject_uid,
             Map.put(mask, "type", "input_image"),
             bytes
           ) do
      {:ok, Map.put(tool, "input_image_mask", Map.delete(mask, "type")), bytes}
    end
  end

  defp inline_local_image_mask(_subject_uid, tool, bytes), do: {:ok, tool, bytes}

  defp inline_local_image_parts(subject_uid, items, bytes) do
    Enum.reduce_while(items, {:ok, [], bytes}, fn item, {:ok, acc, bytes} ->
      case inline_local_item(subject_uid, item, bytes) do
        {:ok, item, bytes} -> {:cont, {:ok, [item | acc], bytes}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, bytes} -> {:ok, Enum.reverse(items), bytes}
      {:error, _reason} = error -> error
    end
  end

  defp inline_local_item(subject_uid, %{"content" => content} = item, bytes)
       when is_list(content) do
    content
    |> Enum.reduce_while({:ok, [], bytes}, fn part, {:ok, acc, bytes} ->
      case inline_local_image_part(subject_uid, part, bytes) do
        {:ok, part, bytes} -> {:cont, {:ok, [part | acc], bytes}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts, bytes} ->
        {:ok, Map.put(item, "content", Enum.reverse(parts)), bytes}

      {:error, _reason} = error ->
        error
    end
  end

  defp inline_local_item(_subject_uid, item, bytes), do: {:ok, item, bytes}

  # A castable `file_`/`ig_` id is Ankole's own namespace, so a dangling one
  # fails loudly. A non-castable `ig_` id belongs to a native provider; when a
  # stored copy exists it inlines, and otherwise the provider judges its own
  # id.
  defp inline_local_image_part(subject_uid, %{"type" => "input_image"} = part, bytes) do
    case Map.get(part, "file_id") do
      "file_" <> uuid = file_id ->
        if castable?(uuid),
          do: inline_artifact(subject_uid, part, &Artifacts.get_file/3, file_id, bytes),
          else: {:ok, part, bytes}

      "ig_" <> uuid = file_id ->
        if castable?(uuid) do
          inline_artifact(
            subject_uid,
            part,
            &Artifacts.get_generated_image/3,
            file_id,
            bytes
          )
        else
          case Artifacts.get_generated_image(subject_uid, file_id, payload?: true) do
            {:ok, artifact} -> inline_artifact(part, artifact, bytes)
            {:error, _missing} -> {:ok, part, bytes}
          end
        end

      _other ->
        {:ok, part, bytes}
    end
  end

  defp inline_local_image_part(_subject_uid, part, bytes), do: {:ok, part, bytes}

  defp inline_artifact(subject_uid, part, getter, file_id, bytes) do
    with {:ok, artifact} <- getter.(subject_uid, file_id, payload?: true) do
      inline_artifact(part, artifact, bytes)
    end
  end

  defp inline_artifact(part, %Artifact{} = artifact, bytes) do
    with {:ok, bytes} <- consume_reference_bytes(bytes, artifact.byte_size) do
      {:ok, inline_part(part, artifact), bytes}
    end
  end

  defp inline_part(part, %Artifact{} = artifact) do
    part
    |> Map.delete("file_id")
    |> Map.put("image_url", data_url(artifact))
  end

  defp castable?(uuid), do: match?({:ok, _id}, UUIDv7.cast(uuid))

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
      {:ok, reference(artifact, id), artifact.byte_size}
    end
  end

  defp resolve_reference(subject_uid, %{kind: :generated, id: id}) do
    with {:ok, artifact} <- Artifacts.get_generated_image(subject_uid, id, payload?: true) do
      {:ok, reference(artifact, id), artifact.byte_size}
    end
  end

  # The caller's reference id stays the downstream correlation key, including
  # when a native provider id resolved through provider_item_id.
  defp reference(%Artifact{} = artifact, id) do
    %{
      "id" => id,
      "image_url" => data_url(artifact),
      "source" => "artifact"
    }
  end

  defp data_url(%Artifact{} = artifact),
    do: "data:#{artifact.mime_type};base64,#{Base.encode64(artifact.payload)}"

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

  defp hydrate_generated_image(
         subject_uid,
         %{"type" => "image_generation_call", "id" => id, "result" => nil} = item,
         bytes
       )
       when is_binary(id) do
    with {:ok, artifact} <- Artifacts.get_generated_image(subject_uid, id, payload?: true),
         {:ok, bytes} <- consume_reference_bytes(bytes, artifact.byte_size) do
      {:ok, Map.put(item, "result", Base.encode64(artifact.payload)), bytes}
    end
  end

  defp hydrate_generated_image(_subject_uid, item, bytes), do: {:ok, item, bytes}

  defp consume_reference_bytes(bytes, size) do
    case ReferenceBudget.consume(bytes, size) do
      {:ok, total} ->
        {:ok, total}

      {:error, :request_too_large} ->
        {:error,
         OpenAIError.invalid(
           "input",
           "request_too_large",
           "Referenced images exceed the 100 MiB request limit."
         )}
    end
  end

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
