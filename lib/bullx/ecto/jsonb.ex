defmodule BullX.Ecto.JSONB do
  @moduledoc false

  use Ecto.Type

  alias BullX.Gateway.JSON

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: normalize(value)

  @impl true
  def load(value), do: normalize(value)

  @impl true
  def dump(value), do: normalize(value)

  defp normalize(value) do
    with {:ok, value} <- JSON.stringify_keys(value),
         true <- JSON.json_neutral?(value) do
      {:ok, value}
    else
      _other -> :error
    end
  end
end
