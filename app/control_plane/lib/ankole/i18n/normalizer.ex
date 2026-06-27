defmodule Ankole.I18n.Normalizer do
  @moduledoc """
  Normalizes decoded TOML locale files into flat MF2 catalogs.

  Locale files are pleasant to author as nested TOML, but runtime lookup should
  stay a simple dotted-key map. This module performs that conversion and validates
  MF2 at load time so the render path does not need parser branches.
  """

  defmodule Error do
    @moduledoc false

    defexception [:message, :file, :path]

    @impl true
    # File and key path are part of the exception because most failures are fixed
    # by translators or release authors in TOML, not by debugging BEAM state.
    def exception(opts) do
      path = Keyword.get(opts, :path, [])
      file = Keyword.get(opts, :file)
      reason = Keyword.fetch!(opts, :reason)
      key = Enum.join(path, ".")

      message =
        "i18n normalization failed at #{file || "<unknown>"}" <>
          case key do
            "" -> ""
            _key -> " (key: #{inspect(key)})"
          end <>
          ": #{reason}"

      %__MODULE__{message: message, file: file, path: path}
    end
  end

  @meta_key "__meta__"
  @mf2_marker "__mf2__"
  @mf2_fields ["message", "description", "placeholders"]
  @meta_allowed_keys ~w(bcp47 fallback revision)

  @type normalized :: %{
          messages: %{String.t() => String.t()},
          meta: map()
        }

  @doc """
  Flattens one decoded TOML table into messages and metadata.

  `__meta__` is kept separate from renderable messages so fallback policy can
  live near the catalog without becoming a translation key.
  """
  @spec normalize(map(), keyword()) :: normalized()
  def normalize(table, opts \\ []) when is_map(table) do
    file = Keyword.get(opts, :file)
    {meta_raw, rest} = Map.pop(table, @meta_key, %{})

    %{
      messages: flatten(rest, [], %{}, file),
      meta: normalize_meta(meta_raw, file)
    }
  end

  # Rich leaves let translators attach notes such as descriptions and placeholder
  # metadata while runtime still stores only the canonical MF2 message.
  defp flatten(node, path, acc, file) when is_map(node) do
    case rich_leaf?(node) do
      true ->
        put_message(acc, path, Map.fetch!(node, "message"), file)

      false ->
        Enum.reduce(node, acc, fn {key, value}, next_acc ->
          flatten(value, path ++ [to_segment(key, path, file)], next_acc, file)
        end)
    end
  end

  defp flatten(binary, path, acc, file) when is_binary(binary) do
    put_message(acc, path, binary, file)
  end

  # Non-string leaves are rejected instead of coerced. A silent coercion would
  # make TOML authoring mistakes look like valid user-facing text.
  defp flatten(other, path, _acc, file) do
    raise Error,
      file: file,
      path: path,
      reason:
        "unsupported leaf type #{inspect(other)}; expected a string or a rich-leaf table with __mf2__ = true"
  end

  defp put_message(_acc, [], _message, file) do
    raise Error, file: file, path: [], reason: "top-level scalar is not allowed"
  end

  # Duplicate dotted keys mean the source file is ambiguous. Failing at load time
  # is cheaper than letting the final map pick a winner by traversal order.
  defp put_message(acc, path, message, file) when is_binary(message) do
    key = Enum.join(path, ".")
    canonical = canonical_message!(message, file, path)

    case Map.has_key?(acc, key) do
      true ->
        raise Error, file: file, path: path, reason: "duplicate key #{inspect(key)}"

      false ->
        Map.put(acc, key, canonical)
    end
  end

  # Localize has returned both bare binaries and tagged tuples across versions.
  # Accepting both keeps the integration small while still rejecting invalid MF2.
  defp canonical_message!(message, file, path) do
    case Localize.Message.canonical_message(message) do
      {:ok, canonical} when is_binary(canonical) ->
        canonical

      canonical when is_binary(canonical) ->
        canonical

      {:error, exception} ->
        raise Error,
          file: file,
          path: path,
          reason: "invalid MF2; #{format_parse_error(exception)}"
    end
  end

  defp format_parse_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_parse_error(reason) when is_binary(reason), do: reason
  defp format_parse_error(reason), do: inspect(reason)

  # Rich leaves are intentionally strict. Unknown fields are likely typos in
  # translator metadata, and silently dropping them would make reviews harder.
  defp rich_leaf?(%{@mf2_marker => true} = map) do
    allowed = [@mf2_marker | @mf2_fields]

    Enum.all?(Map.keys(map), &(&1 in allowed)) and
      Map.has_key?(map, "message") and is_binary(Map.fetch!(map, "message"))
  end

  defp rich_leaf?(_map), do: false

  defp to_segment(key, _path, _file) when is_binary(key) and key != "", do: key

  # Empty or non-string keys would create dotted keys that humans cannot reason
  # about, so they are rejected before entering the runtime catalog.
  defp to_segment(key, path, file) when is_binary(key) do
    raise Error, file: file, path: path, reason: "empty segment"
  end

  defp to_segment(key, path, file) do
    raise Error, file: file, path: path, reason: "non-string segment #{inspect(key)}"
  end

  # Metadata is a small policy surface today. Keeping it as a table makes future
  # additions explicit and avoids mixing policy values with messages.
  defp normalize_meta(meta, file) when is_map(meta) do
    Enum.reduce(meta, %{}, fn {key, value}, acc ->
      put_meta_entry(acc, key, value, file)
    end)
  end

  defp normalize_meta(_meta, file) do
    raise Error, file: file, path: [@meta_key], reason: "meta table must be an object"
  end

  # Metadata values stay strings because they map to catalog text such as locale
  # ids and revisions. Other TOML types would invite implicit conversion rules.
  defp put_meta_entry(acc, "bcp47", value, _file) when is_binary(value),
    do: Map.put(acc, :bcp47, value)

  defp put_meta_entry(acc, "fallback", value, _file) when is_binary(value),
    do: Map.put(acc, :fallback, value)

  defp put_meta_entry(acc, "revision", value, _file) when is_binary(value),
    do: Map.put(acc, :revision, value)

  defp put_meta_entry(_acc, key, _value, file) when key in @meta_allowed_keys do
    raise Error,
      file: file,
      path: [@meta_key, key],
      reason: "meta key #{inspect(key)} must be a string"
  end

  defp put_meta_entry(_acc, key, _value, file) do
    raise Error,
      file: file,
      path: [@meta_key, to_string(key)],
      reason: "unknown meta key #{inspect(key)}; allowed: #{inspect(@meta_allowed_keys)}"
  end
end
