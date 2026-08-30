defmodule Ankole.Attrs do
  @moduledoc """
  Shared normalization for external attribute maps.

  Console controllers and subsystem writers accept caller-supplied attribute
  maps with atom or string keys. This module holds the transforms that are
  identical across subsystems, so each subsystem keeps only its own domain
  rules.
  """

  @doc """
  Puts the value unless it is `nil`.
  """
  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Puts the value unless it is `nil` or the empty string.
  """
  @spec put_present(map(), term(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, _key, ""), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Collects `{:ok, value}` results in order and halts on the first error.
  """
  @spec collect_results(Enumerable.t()) :: {:ok, [term()]} | {:error, term()}
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

  @doc """
  Converts top-level atom keys to strings and keeps values unchanged.
  """
  @spec normalize_external_attrs(map()) :: map()
  def normalize_external_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
