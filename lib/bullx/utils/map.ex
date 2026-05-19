defmodule BullX.Utils.Map do
  @moduledoc """
  Pure map / value helpers extracted from per-plugin duplications.

  Only helpers whose semantics are byte-identical across all current call sites
  live here. Variants with diverging semantics (e.g. `first_present` with and
  without trim, `map_value` with and without atom-key fallback) stay local to
  their callers.
  """

  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec reject_nil_values(map()) :: map()
  def reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @spec positive_integer(map(), term(), term()) :: term()
  def positive_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  @spec bounded_integer(map(), term(), term(), integer(), integer()) :: term()
  def bounded_integer(map, key, default, min, max) do
    case positive_integer(map, key, default) do
      value when value >= min and value <= max -> value
      value when value > max -> max
      _value -> default
    end
  end

  @spec non_negative_integer(map(), term(), term()) :: term()
  def non_negative_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  @spec optional_boolean(map(), term(), term()) :: term()
  def optional_boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  @spec stringify_id(term()) :: String.t() | nil
  def stringify_id(value) when is_binary(value) and value != "", do: String.trim(value)
  def stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  def stringify_id(_value), do: nil

  @spec string_list(map(), term(), term()) :: term()
  def string_list(map, key, default) do
    case Map.get(map, key, default) do
      values when is_list(values) -> values |> Enum.map(&stringify_id/1) |> Enum.reject(&is_nil/1)
      _value -> default
    end
  end

  @doc """
  Returns the input binary trimmed if non-empty, otherwise `nil`.

  Mirrors the `present_string/1` defined in `*/source.ex` files (trim-then-check
  semantics). Do not use to replace variants that intentionally skip trimming
  (e.g. `feishu/event_mapper.ex`).
  """
  @spec present_string(term()) :: String.t() | nil
  def present_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  def present_string(_value), do: nil
end
