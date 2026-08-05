defmodule Ankole.Plugins.ConfigSecrets do
  @moduledoc """
  Preserves and redacts plugin-declared encrypted configuration fields.

  Plugin field paths can be nested and can use atom or string descriptor keys.
  """

  @spec preserve(list(), map(), map(), [String.t()]) :: map()
  def preserve(fields, patch, current, preserved_placeholders \\ []) do
    fields
    |> encrypted_field_paths()
    |> Enum.reduce(patch, fn path, config ->
      case {placeholder?(get_path(config, path), preserved_placeholders), get_path(current, path)} do
        {true, value} when not is_nil(value) -> put_path(config, path, value)
        _value -> config
      end
    end)
  end

  @spec redact(list(), map()) :: {map(), [String.t()]}
  def redact(fields, config) do
    fields
    |> encrypted_field_paths()
    |> Enum.reduce({config, []}, fn path, {redacted, stored_paths} ->
      case is_nil(get_path(config, path)) do
        true -> {redacted, stored_paths}
        false -> {delete_path(redacted, path), [path | stored_paths]}
      end
    end)
    |> then(fn {redacted, stored_paths} -> {redacted, Enum.reverse(stored_paths)} end)
  end

  defp encrypted_field_paths(fields) when is_list(fields) do
    fields
    |> Enum.filter(&(field_value(&1, :encrypted) == true))
    |> Enum.map(&field_value(&1, :path))
    |> Enum.filter(&is_binary/1)
  end

  defp encrypted_field_paths(_fields), do: []

  defp field_value(field, key) when is_map(field) do
    Map.get(field, key, Map.get(field, Atom.to_string(key)))
  end

  defp field_value(_field, _key), do: nil

  defp placeholder?(nil, _preserved_placeholders), do: true
  defp placeholder?("", _preserved_placeholders), do: true

  defp placeholder?(value, preserved_placeholders),
    do: value in preserved_placeholders

  defp get_path(source, path) when is_map(source) and is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(source, fn segment, value ->
      case value do
        value when is_map(value) -> {:cont, Map.get(value, segment)}
        _value -> {:halt, nil}
      end
    end)
  end

  defp get_path(_source, _path), do: nil

  defp put_path(source, path, value) when is_map(source) and is_binary(path) do
    do_put_path(source, String.split(path, "."), value)
  end

  defp delete_path(source, path) when is_map(source) and is_binary(path) do
    do_delete_path(source, String.split(path, "."))
  end

  defp do_delete_path(source, [segment]), do: Map.delete(source, segment)

  defp do_delete_path(source, [segment | rest]) do
    case Map.get(source, segment) do
      child when is_map(child) -> Map.put(source, segment, do_delete_path(child, rest))
      _value -> source
    end
  end

  defp do_put_path(source, [segment], value), do: Map.put(source, segment, value)

  defp do_put_path(source, [segment | rest], value) do
    child =
      case Map.get(source, segment) do
        child when is_map(child) -> child
        _value -> %{}
      end

    Map.put(source, segment, do_put_path(child, rest, value))
  end
end
