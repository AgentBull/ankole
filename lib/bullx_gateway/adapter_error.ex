defmodule BullXGateway.AdapterError do
  @moduledoc """
  Builds the JSON-neutral error maps expected from Gateway adapters.

  Adapter modules still own platform-specific classification. This module owns
  only the shared wire shape: string keys, string `kind`, human message, and
  string-keyed details.
  """

  @type t :: %{
          required(String.t()) => term()
        }

  @spec new(String.t(), String.t(), map()) :: t()
  def new(kind, message, details \\ %{})
      when is_binary(kind) and is_binary(message) and is_map(details) do
    %{"kind" => kind, "message" => message, "details" => stringify(details)}
  end

  @spec stringify(map()) :: map()
  def stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  @spec put_present(map(), String.t(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
