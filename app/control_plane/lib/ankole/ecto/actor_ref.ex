defmodule Ankole.Ecto.ActorRef do
  @moduledoc """
  Stores tenant-qualified Principal attribution as text.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(value), do: Ankole.ActorRef.cast(value)

  @impl true
  def load(value) when is_binary(value), do: cast(value)
  def load(_), do: :error

  @impl true
  def dump(value) do
    case cast(value) do
      {:ok, reference} -> {:ok, to_string(reference)}
      :error -> :error
    end
  end
end
