defmodule Ankole.Plugins.MapHelpers do
  @moduledoc """
  Decode helpers for the weak-typed provider payload maps handled by Control
  Plane Plugin adapters. Provider and configuration JSON maps use string keys.
  These helpers do not accept atom-key aliases.
  """

  @spec fetch_value(term(), String.t()) :: term()
  def fetch_value(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)

  def fetch_value(_map, _key), do: nil

  @spec fetch_map(term(), term(), map()) :: map()
  def fetch_map(map, key, default) when is_map(map) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  def fetch_map(_map, _key, default), do: default

  @spec fetch_list(term(), term()) :: list()
  def fetch_list(map, key) when is_map(map) do
    case fetch_value(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  def fetch_list(_map, _key), do: []

  @spec optional_text(term(), term()) :: String.t() | nil
  def optional_text(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) -> presence(value)
      _value -> nil
    end
  end

  @spec presence(term()) :: String.t() | nil
  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  def presence(_value), do: nil

  @spec required_string(term(), String.t()) ::
          {:ok, String.t()} | {:error, {:missing, String.t()}}
  def required_string(map, key) do
    case optional_text(map, key) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  @spec optional_string(term(), String.t(), term()) ::
          {:ok, term()} | {:error, {:invalid_string, String.t()}}
  def optional_string(map, key, default) do
    case fetch_value(map, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, presence(value) || default}
      _value -> {:error, {:invalid_string, key}}
    end
  end

  @spec optional_boolean(term(), String.t(), term()) ::
          {:ok, term()} | {:error, {:invalid_boolean, String.t()}}
  def optional_boolean(map, key, default) do
    case fetch_value(map, key) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  @spec integer_between(term(), String.t(), term(), integer(), integer()) ::
          {:ok, term()} | {:error, {:invalid_integer_range, String.t(), integer(), integer()}}
  def integer_between(map, key, default, min, max) do
    case fetch_value(map, key) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_integer_range, key, min, max}}
    end
  end

  @spec compact_map(map()) :: map()
  def compact_map(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @spec compact_metadata_map(map()) :: map()
  def compact_metadata_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == [] end)
  end

  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_nonempty_map(map(), term(), term()) :: map()
  def maybe_put_nonempty_map(map, _key, nil), do: map

  def maybe_put_nonempty_map(map, _key, value) when is_map(value) and map_size(value) == 0,
    do: map

  def maybe_put_nonempty_map(map, key, value), do: Map.put(map, key, value)

  @spec collect_results([term()]) :: {:ok, [term()]} | {:error, term()}
  def collect_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
