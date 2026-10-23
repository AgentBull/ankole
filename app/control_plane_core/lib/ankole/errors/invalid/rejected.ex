defmodule Ankole.Errors.Invalid.Rejected do
  @moduledoc """
  Carries a declared domain rejection reason through an Ash action.

  The reason stays an atom or a tuple. `Ankole.Errors.reason/1` gives it back to
  domain code. The message does not contain the reason or the input values.
  """

  use Splode.Error, fields: [:reason], class: :invalid

  def message(_error), do: "The domain operation was rejected"

  @doc """
  Gives the API error code of a reason: the atom, or the first atom of a
  tuple. Other reasons give `"rejected"`.
  """
  def code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def code(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: code(elem(reason, 0))
  def code(_reason), do: "rejected"

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(error),
      do: %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 422,
        code: Ankole.Errors.Invalid.Rejected.code(error.reason),
        title: "Rejected",
        detail: "the domain operation was rejected"
      }
  end
end
