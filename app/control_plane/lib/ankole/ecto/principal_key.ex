defmodule Ankole.Ecto.PrincipalKey do
  @moduledoc """
  Ecto type for installation-wide Principal UID fields.

  The database column is text, but schema casts and dumps normalize through
  `Ankole.PrincipalKey` so Principal foreign keys do not each reimplement the
  same lowercase/trim rule.
  """

  use Ecto.Type

  alias Ankole.PrincipalKey

  @impl true
  def type, do: :string

  @impl true
  def cast(value), do: normalize_optional(value)

  @impl true
  def dump(value), do: normalize_optional(value)

  @impl true
  def load(value), do: normalize_optional(value)

  defp normalize_optional(value) do
    case PrincipalKey.normalize_optional(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :invalid_uid} -> :error
    end
  end
end
