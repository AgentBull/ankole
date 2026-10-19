defmodule Ankole.Ecto.JSONList do
  @moduledoc "Stores one JSON array in a PostgreSQL JSONB column."
  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) do
    case Ankole.Ecto.JSONPayload.normalize_list(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def load(value), do: cast(value)

  @impl true
  def dump(value), do: cast(value)
end
