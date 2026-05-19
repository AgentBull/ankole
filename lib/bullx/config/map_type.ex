defmodule BullX.Config.MapType do
  @moduledoc """
  Pure value-validation helpers for plugin Skogsra `cast/1` implementations
  that decode configuration maps into normalized records.

  All helpers return `{:ok, value} | :error` matching Skogsra's expectation.
  Keep this module focused on the byte-identical helpers shared across
  plugins; per-plugin variants (e.g. each plugin's `stringify_value/1`, which
  diverges in how it handles invalid nested maps) stay local.
  """

  @spec required_string(map(), term()) :: {:ok, String.t()} | :error
  def required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  @spec optional_string(map(), term(), term()) :: {:ok, String.t()} | :error
  def optional_string(map, key, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  @spec optional_boolean(map(), term(), term()) :: {:ok, boolean()} | :error
  def optional_boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> :error
    end
  end

  @spec optional_map(map(), term(), term()) :: {:ok, map()} | :error
  def optional_map(map, key, default) do
    case Map.get(map, key, default) do
      value when is_map(value) -> {:ok, value}
      _value -> :error
    end
  end
end
