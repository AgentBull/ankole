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
  def optional_text(map, key), do: map |> fetch_value(key) |> Ankole.Attrs.optional_text()

  @spec presence(term()) :: String.t() | nil
  defdelegate presence(value), to: Ankole.Attrs, as: :optional_text

  @doc """
  Returns `nil` for the empty string and keeps every other value unchanged.
  """
  @spec blank_to_nil(term()) :: term()
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value

  @doc """
  Fetches one required non-empty string option from a keyword list.
  """
  @spec required_opt(keyword(), atom()) :: {:ok, String.t()} | {:error, {:missing, atom()}}
  def required_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  @spec required_string(term(), String.t()) ::
          {:ok, String.t()} | {:error, {:missing, String.t()}}
  def required_string(map, key),
    do: Ankole.Attrs.required_text(fetch_value(map, key), {:missing, key})

  @spec optional_string(term(), String.t(), term()) ::
          {:ok, term()} | {:error, {:invalid_string, String.t()}}
  def optional_string(map, key, default) do
    case fetch_value(map, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, presence(value) || default}
      _value -> {:error, {:invalid_string, key}}
    end
  end

  @doc """
  Reads a string list, trims each entry, and rejects blank entries.
  """
  @spec string_array(term(), String.t(), term()) ::
          {:ok, term()} | {:error, {:invalid_string_array, String.t()}}
  def string_array(map, key, default) do
    case fetch_value(map, key) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:error, {:invalid_string_array, key}}
        end

      nil ->
        {:ok, default}

      _value ->
        {:error, {:invalid_string_array, key}}
    end
  end

  @doc """
  Reads an optional string and requires it to be one of the supplied values.
  """
  @spec enum_string(term(), String.t(), [String.t()], term()) ::
          {:ok, term()} | {:error, term()}
  def enum_string(map, key, values, default) do
    with {:ok, value} <- optional_string(map, key, default) do
      case value in values do
        true -> {:ok, value}
        false -> {:error, {:invalid_enum, key, values}}
      end
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

  @spec put_present(map(), term(), term()) :: map()
  defdelegate put_present(map, key, value), to: Ankole.Attrs

  @spec maybe_put_nonempty_map(map(), term(), term()) :: map()
  def maybe_put_nonempty_map(map, _key, nil), do: map

  def maybe_put_nonempty_map(map, _key, value) when is_map(value) and map_size(value) == 0,
    do: map

  def maybe_put_nonempty_map(map, key, value), do: Map.put(map, key, value)

  @spec collect_results([term()]) :: {:ok, [term()]} | {:error, term()}
  defdelegate collect_results(results), to: Ankole.Attrs
end
