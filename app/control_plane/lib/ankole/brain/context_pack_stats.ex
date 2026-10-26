defmodule Ankole.Brain.ContextPackStats do
  @moduledoc """
  Node-local counters for the context-pack injection surface.

  The health page reports how many packs this node served and how many
  degraded to empty since boot. Counters live in a `:persistent_term`
  anchored `:counters` array: they survive caller crashes, cost nothing on
  the turn path, and are observability, not durable state.
  """

  @key __MODULE__

  @served_index 1
  @degraded_index 2

  @spec record(:served | :degraded) :: :ok
  def record(:served), do: :counters.add(ref(), @served_index, 1)
  def record(:degraded), do: :counters.add(ref(), @degraded_index, 1)

  @spec snapshot() :: %{served: non_neg_integer(), degraded: non_neg_integer()}
  def snapshot do
    ref = ref()

    %{
      served: :counters.get(ref, @served_index),
      degraded: :counters.get(ref, @degraded_index)
    }
  end

  defp ref do
    case :persistent_term.get(@key, nil) do
      nil ->
        :persistent_term.put(@key, :counters.new(2, [:write_concurrency]))
        :persistent_term.get(@key)

      ref ->
        ref
    end
  end
end
