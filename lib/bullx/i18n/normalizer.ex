defmodule BullX.I18n.Normalizer do
  @moduledoc """
  Flattens a decoded TOML tree into the canonical catalog shape.

  ## Input

  A nested map of string-keyed tables produced by `TomlElixir.decode/2`:

      %{
        "__meta__" => %{"bcp47" => "en-US"},
        "examples" => %{
          "greeting" => "Hello, {$name}!",
          "profile" => %{"title" => "Profile"}
        },
        "commerce" => %{
          "cart" => %{
            "checkout_button" => %{
              "__mf2__" => true,
              "message" => "Checkout {$total}"
            }
          }
        }
      }

  ## Output

  `%{messages: %{String.t() => String.t()}, meta: %{optional(atom()) => any}}`
  where `messages` is keyed by dotted path and each value is the
  canonical MF2 source; `meta` holds the reserved `__meta__` table.

  Any leaf that is not a string or a rich-leaf table raises a
  `BullX.I18n.NormalizeError`.
  """

  defmodule Error do
    @moduledoc false
    defexception [:message, :file, :path]

    @impl true
    def exception(opts) do
      path = Keyword.get(opts, :path, [])
      file = Keyword.get(opts, :file)
      reason = Keyword.fetch!(opts, :reason)
      key = Enum.join(path, ".")

      msg =
        "i18n normalization failed at #{file || "<unknown>"}" <>
          if(key == "", do: "", else: " (key: #{inspect(key)})") <> ": #{reason}"

      %__MODULE__{message: msg, file: file, path: path}
    end
  end

  @meta_key "__meta__"
  @mf2_marker "__mf2__"
  @mf2_fields ["message", "description", "placeholders"]

  @type normalized :: %{
          messages: %{String.t() => String.t()},
          meta: map()
        }

  @spec normalize(map(), Keyword.t()) :: normalized()
  def normalize(table, opts \\ []) when is_map(table) do
    file = Keyword.get(opts, :file)

    {meta_raw, rest} = Map.pop(table, @meta_key, %{})
    messages = flatten(rest, [], %{}, file)

    %{messages: messages, meta: normalize_meta(meta_raw, file)}
  end

  defp flatten(node, path, acc, file) when is_map(node) do
    cond do
      rich_leaf?(node) ->
        put_message(acc, path, Map.fetch!(node, "message"), file)

      true ->
        Enum.reduce(node, acc, fn {key, value}, acc ->
          flatten(value, path ++ [to_segment(key, path, file)], acc, file)
        end)
    end
  end

  defp flatten(binary, path, acc, file) when is_binary(binary) do
    put_message(acc, path, binary, file)
  end

  defp flatten(other, path, _acc, file) do
    raise Error,
      file: file,
      path: path,
      reason:
        "unsupported leaf type #{inspect(other)} — expected a string or a rich-leaf table with __mf2__ = true"
  end

  defp put_message(_acc, [], _msg, file) do
    raise Error, file: file, path: [], reason: "top-level scalar is not allowed"
  end

  defp put_message(acc, path, message, file) when is_binary(message) do
    key = Enum.join(path, ".")

    canonical =
      case Localize.Message.canonical_message(message) do
        {:ok, canonical} ->
          canonical

        {:error, exception} ->
          raise Error,
            file: file,
            path: path,
            reason: "invalid MF2 — #{format_parse_error(exception)}"
      end

    if Map.has_key?(acc, key) do
      raise Error,
        file: file,
        path: path,
        reason: "duplicate key #{inspect(key)}"
    end

    Map.put(acc, key, canonical)
  end

  defp format_parse_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_parse_error(reason) when is_binary(reason), do: reason
  defp format_parse_error(reason), do: inspect(reason)

  defp rich_leaf?(%{@mf2_marker => true} = map) do
    allowed = [@mf2_marker | @mf2_fields]

    Enum.all?(Map.keys(map), fn k -> k in allowed end) and
      Map.has_key?(map, "message") and
      is_binary(Map.fetch!(map, "message"))
  end

  defp rich_leaf?(_), do: false

  defp to_segment(key, path, file) when is_binary(key) do
    if key == "" do
      raise Error, file: file, path: path, reason: "empty segment"
    end

    key
  end

  @meta_allowed_keys ~w(bcp47 fallback revision)

  defp normalize_meta(meta, file) when is_map(meta) do
    Enum.reduce(meta, %{}, fn {key, value}, acc ->
      put_meta_entry(acc, key, value, file)
    end)
  end

  defp put_meta_entry(acc, "bcp47", v, _file) when is_binary(v), do: Map.put(acc, :bcp47, v)
  defp put_meta_entry(acc, "fallback", v, _file) when is_binary(v), do: Map.put(acc, :fallback, v)
  defp put_meta_entry(acc, "revision", v, _file) when is_binary(v), do: Map.put(acc, :revision, v)

  defp put_meta_entry(_acc, key, _v, file) when key in @meta_allowed_keys do
    raise Error,
      file: file,
      path: [@meta_key, key],
      reason: "meta key #{inspect(key)} must be a string"
  end

  defp put_meta_entry(_acc, key, _v, file) do
    raise Error,
      file: file,
      path: [@meta_key, to_string(key)],
      reason: "unknown meta key #{inspect(key)}; allowed: #{inspect(@meta_allowed_keys)}"
  end
end
