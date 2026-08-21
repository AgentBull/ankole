defmodule Ankole.AIGateway.MapUtils do
  @moduledoc """
  Small normalization helpers shared at AIGateway JSON boundaries.

  External JSON maps use string keys. These helpers keep the provider boundary
  predictable without pulling larger schema or struct machinery into the
  provider preparation path.
  """

  @doc "Normalizes atom keys to string keys at an external JSON boundary."
  defdelegate normalize_request_keys(map), to: Ankole.Attrs, as: :normalize_external_attrs
end
