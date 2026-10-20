defmodule Ankole.Brain.Ecto.StringList do
  @moduledoc """
  JSONB-backed list of strings, used where the design fixes a jsonb column
  that always carries a JSON array of strings.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :error
  end

  def cast(_value), do: :error

  @impl true
  def load(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :error
  end

  def load(_value), do: :error

  @impl true
  def dump(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :error
  end

  def dump(_value), do: :error
end
