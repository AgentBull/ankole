defmodule Ankole.Ecto.Changeset do
  @moduledoc """
  Shared changeset normalization helpers for ordinary text fields.

  Principal UID normalization belongs to `Ankole.Ecto.PrincipalKey`; this module
  only owns non-domain text cleanup used by many schemas.
  """

  import Ecto.Changeset

  @doc """
  Trims binary field changes and converts blank strings to nil.
  """
  @spec normalize_blank(Ecto.Changeset.t(), atom() | [atom()]) :: Ecto.Changeset.t()
  def normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  def normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  @doc """
  Lowercases binary field changes without trimming them.
  """
  @spec normalize_lower(Ecto.Changeset.t(), atom() | [atom()]) :: Ecto.Changeset.t()
  def normalize_lower(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_lower(&2, &1))
  end

  def normalize_lower(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
