defmodule Ankole.AIGateway.ReasoningEffort.Levels do
  @moduledoc """
  Holds the public `reasoningEffort` levels.

  Provider definitions read these levels at compile time. This module must have
  no dependencies, so that the compile edge from a provider does not go into the
  runtime cycle of `Ankole.AIGateway.ReasoningEffort` and model metadata.
  """

  @values ~w(none minimal low medium high xhigh max ultra)

  @doc "Returns the canonical levels accepted by Ankole, optionally narrowed by a provider map."
  @spec values(map() | nil) :: [String.t()]
  def values(map \\ nil)
  def values(nil), do: @values
  def values(map) when is_map(map), do: Enum.filter(@values, &Map.has_key?(map, &1))
end
