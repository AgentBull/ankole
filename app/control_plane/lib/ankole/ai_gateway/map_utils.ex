defmodule Ankole.AIGateway.MapUtils do
  @moduledoc """
  Small normalization helpers shared at AIGateway JSON boundaries.

  External JSON maps use string keys. These helpers keep the provider boundary
  predictable without pulling larger schema or struct machinery into the
  provider preparation path.
  """

  @doc "Normalizes atom keys to string keys at an external JSON boundary."
  def normalize_request_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
