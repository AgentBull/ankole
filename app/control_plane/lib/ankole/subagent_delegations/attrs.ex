defmodule Ankole.SubagentDelegations.Attrs do
  @moduledoc false

  @spec normalize(map()) :: map()
  def normalize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  @spec text(map(), String.t()) :: String.t() | nil
  def text(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  @spec reject_nil_values(map()) :: map()
  def reject_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
