defmodule Ankole.Schedule.Attrs do
  @moduledoc false

  @spec bounded_text(map(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def bounded_text(map, key, max_length) do
    with {:ok, value} <- required_text(map, key),
         true <- String.length(value) <= max_length do
      {:ok, value}
    else
      false -> {:error, {:text_too_long, key}}
      {:error, _reason} = error -> error
    end
  end

  @spec optional_bounded_text(map(), String.t(), pos_integer()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def optional_bounded_text(map, key, max_length) do
    case map_text(map, key) do
      nil ->
        {:ok, nil}

      value when byte_size(value) == 0 ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.length(value) <= max_length do
          true -> {:ok, value}
          false -> {:error, {:text_too_long, key}}
        end
    end
  end

  @spec required_text(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def required_text(map, key) when is_map(map) do
    case map_text(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_text, key}}
    end
  end

  @spec map_text(map() | nil, String.t()) :: String.t() | nil
  def map_text(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  def map_text(_map, _key), do: nil

  @spec map_value(map() | nil, String.t()) :: term()
  def map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  def map_value(_map, _key), do: nil

  @spec positive_integer(map(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def positive_integer(map, key) do
    with {:ok, value} <- integer_value(map, key),
         true <- value > 0 do
      {:ok, value}
    else
      _value -> {:error, {:invalid_positive_integer, key}}
    end
  end

  @spec parse_positive_integer(term()) :: {:ok, pos_integer()} | {:error, :invalid_integer}
  def parse_positive_integer(value) do
    with {:ok, integer} <- parse_integer(value),
         true <- integer > 0 do
      {:ok, integer}
    else
      _value -> {:error, :invalid_integer}
    end
  end

  @spec reject_nil_values(map()) :: map()
  def reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defdelegate maybe_put(map, key, value), to: Ankole.Attrs

  @spec collect_results([{:ok, term()} | {:error, term()}]) :: {:ok, [term()]} | {:error, term()}
  defdelegate collect_results(results), to: Ankole.Attrs

  defp integer_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) -> parse_integer(value)
      _value -> {:error, {:missing_integer, key}}
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _value -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}
  defp parse_integer(_value), do: {:error, :invalid_integer}
end
