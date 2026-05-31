defmodule BullX.Ecto.JSONB do
  @moduledoc """
  Ecto type for JSONB fields that must contain JSON-neutral values.

  The type normalizes atom keys to strings on cast/load/dump so database facts
  stay provider- and language-neutral instead of preserving Elixir-only map
  shapes.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: normalize(value)

  @impl true
  def load(value), do: normalize(value)

  @impl true
  def dump(value), do: normalize(value)

  defp normalize(value) do
    with {:ok, value} <- BullX.JSON.stringify_keys(value),
         true <- BullX.JSON.json_neutral?(value) do
      {:ok, value}
    else
      _other -> :error
    end
  end
end
