defmodule Ankole.Brain.ModelCalls do
  @moduledoc """
  One-shot stateless model calls for Brain system tasks.

  Extraction and Dreaming use the maintainer Agent's model profiles. Calls run
  as that Agent, so model usage belongs to it. Calls are stateless: no
  conversation rows, no history.
  """

  alias Ankole.AIGateway
  alias Ankole.Brain.Config
  alias Ankole.JSON

  @doc """
  Runs one prompt against a resolved model profile and returns the output text.
  """
  @spec complete_text(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete_text(model, prompt, opts \\ []) when is_map(model) and is_binary(prompt) do
    request =
      %{
        "model" => model["provider_id"] <> "/" <> model["model"],
        "input" => prompt,
        "store" => false
      }
      |> maybe_put_provider_options(model)
      |> Map.merge(Keyword.get(opts, :request_overrides, %{}))

    with {:ok, subject_uid} <- Config.maintainer_subject_uid() do
      case AIGateway.create_response(subject_uid, request) do
        {:ok, %{body: body}} -> extract_output_text(body)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Runs one prompt and decodes the output as one JSON object.

  Models without structured output often put analysis prose around the
  object, so decoding tries the whole text, then fenced code blocks, then
  every top-level balanced object — each last-first, because the final
  answer comes last. A slice from the first `{` to the last `}` would fuse
  several objects into invalid JSON, so extraction is a string-aware
  balanced scan instead.
  """
  @spec complete_json(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_json(model, prompt, opts \\ []) do
    with {:ok, text} <- complete_text(model, prompt, opts) do
      decode_json_object(text)
    end
  end

  @doc false
  @spec decode_json_object(String.t()) :: {:ok, map()} | {:error, term()}
  def decode_json_object(text) when is_binary(text) do
    candidates =
      [String.trim(text)] ++ fenced_blocks(text) ++ Enum.reverse(balanced_objects(text))

    Enum.find_value(candidates, {:error, :model_output_not_json}, fn candidate ->
      case JSON.decode(candidate) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        _not_an_object -> nil
      end
    end)
  end

  defp maybe_put_provider_options(request, model) do
    case Map.get(model, "provider_options") do
      options when is_map(options) and map_size(options) > 0 ->
        Map.put(request, "provider_options", options)

      _empty ->
        request
    end
  end

  defp extract_output_text(body) do
    text =
      body
      |> Map.get("output", [])
      |> Enum.flat_map(fn
        %{"type" => "message", "content" => content} when is_list(content) -> content
        _other -> []
      end)
      |> Enum.flat_map(fn
        %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
        _other -> []
      end)
      |> Enum.join("")

    case String.trim(text) do
      "" -> {:error, :empty_model_output}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fenced_blocks(text) do
    ~r/```[a-zA-Z]*\s*\n([\s\S]*?)```/u
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [inner] -> String.trim(inner) end)
    |> Enum.reverse()
  end

  defp balanced_objects(text), do: scan_objects(text, 0, text, [])

  defp scan_objects(<<>>, _offset, _text, acc), do: Enum.reverse(acc)

  defp scan_objects(<<?{, _rest::binary>> = at_brace, offset, text, acc) do
    case object_length(at_brace, 0, 0, false, false) do
      {:ok, length} ->
        slice = binary_part(text, offset, length)
        remaining = binary_part(at_brace, length, byte_size(at_brace) - length)
        scan_objects(remaining, offset + length, text, [slice | acc])

      :unbalanced ->
        Enum.reverse(acc)
    end
  end

  defp scan_objects(<<_byte, rest::binary>>, offset, text, acc),
    do: scan_objects(rest, offset + 1, text, acc)

  # Byte-wise walking is structure-safe: braces, quotes, and backslashes
  # are ASCII and never appear inside UTF-8 continuation bytes.
  defp object_length(<<byte, rest::binary>>, depth, length, in_string, escaped) do
    cond do
      escaped -> object_length(rest, depth, length + 1, in_string, false)
      in_string and byte == ?\\ -> object_length(rest, depth, length + 1, true, true)
      byte == ?" -> object_length(rest, depth, length + 1, not in_string, false)
      in_string -> object_length(rest, depth, length + 1, true, false)
      byte == ?{ -> object_length(rest, depth + 1, length + 1, false, false)
      byte == ?} and depth == 1 -> {:ok, length + 1}
      byte == ?} -> object_length(rest, depth - 1, length + 1, false, false)
      true -> object_length(rest, depth, length + 1, false, false)
    end
  end

  defp object_length(<<>>, _depth, _length, _in_string, _escaped), do: :unbalanced
end
