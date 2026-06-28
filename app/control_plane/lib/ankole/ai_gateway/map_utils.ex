defmodule Ankole.AIGateway.MapUtils do
  @moduledoc """
  Small normalization helpers shared by AIGateway body translators.

  External JSON maps use string keys. These helpers keep the provider boundary
  predictable without pulling larger schema or struct machinery into request and
  response conversion code.
  """

  @doc "Normalizes atom keys to string keys at an external JSON boundary."
  def normalize_request_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  def put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      "" -> Map.put(map, key, value)
      _value -> map
    end
  end

  @doc """
  Returns an upstream body value, falling back to the public request when needed.

  Many upstream APIs omit request echoes such as `instructions` or `tools`.
  Normalized Responses bodies still need those fields, so request values are the
  safe fallback when the upstream body has no useful value.
  """
  def preferred_value(body, request, key) do
    case Map.fetch(body, key) do
      {:ok, nil} -> Map.get(request, key)
      {:ok, value} -> value
      :error -> Map.get(request, key)
    end
  end

  def integer_value(value) when is_integer(value), do: value
  def integer_value(value) when is_float(value), do: trunc(value)
  def integer_value(_value), do: nil

  def number_value(value, _default) when is_number(value), do: value
  def number_value(_value, default), do: default

  def boolean_value(value, _default) when is_boolean(value), do: value
  def boolean_value(_value, default), do: default

  def string_value(value) when is_binary(value) and value != "", do: value
  def string_value(_value), do: nil

  def nullable_string(value) when is_binary(value), do: value
  def nullable_string(_value), do: nil

  def blank_string?(nil), do: true
  def blank_string?(value) when is_binary(value), do: String.trim(value) == ""
  def blank_string?(_value), do: false

  def now_seconds, do: System.system_time(:second)

  def normalize_usage_map(usage) when is_map(usage), do: normalize_request_keys(usage)
  def normalize_usage_map(_usage), do: %{}
end
