defmodule Ankole.Errors.Invalid.Rejected do
  @moduledoc """
  Carries a declared domain rejection reason through an Ash action.

  The reason stays an atom or a tuple. `Ankole.Errors.reason/1` gives it back to
  domain code. The message does not contain the reason or the input values.

  `Ankole.Errors.wrap/2` can add `detail`, one sentence for the operator,
  `details`, the rejected fields, and `status`, 409 for a conflict with the
  current state. Only the v2 JSON:API error shows them, as the `detail`, the
  `meta.details`, and the status of the error.
  """

  use Splode.Error, fields: [:reason, :detail, details: [], status: 422], class: :invalid

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
        status_code: error.status,
        code: Ankole.Errors.Invalid.Rejected.code(error.reason),
        title: "Rejected",
        detail: error.detail || "the domain operation was rejected",
        meta: if(error.details == [], do: :undefined, else: %{details: error.details})
      }
  end
end
