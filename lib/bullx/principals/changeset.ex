defmodule BullX.Principals.Changeset do
  @moduledoc """
  Shared changeset helpers for Principal extension schemas.

  Principal-facing forms frequently distinguish blank user input from absent
  facts. These helpers normalize blank strings and validate JSON-map metadata
  consistently across Human, Agent, and external identity rows.
  """

  import Ecto.Changeset

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

  def validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_map(value) do
        true -> []
        false -> [{field, "must be a map"}]
      end
    end)
  end
end
