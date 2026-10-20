defmodule Ankole.BackgroundAgentJobs.Attrs do
  @moduledoc false

  @spec normalize(map()) :: map()
  defdelegate normalize(map), to: Ankole.Attrs, as: :normalize_external_attrs

  @spec text(map(), String.t()) :: String.t() | nil
  def text(map, key) when is_map(map) and is_binary(key),
    do: map |> Ankole.Attrs.get_truthy(key) |> Ankole.Attrs.optional_text()

  @spec reject_nil_values(map()) :: map()
  def reject_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
