defmodule Ankole.Errors.Invalid.Rejected do
  @moduledoc """
  Carries a declared domain rejection reason through an Ash action.

  The reason stays an atom or a tuple. `Ankole.Errors.reason/1` gives it back to
  domain code. The message does not contain the reason or the input values.
  """

  use Splode.Error, fields: [:reason], class: :invalid

  def message(_error), do: "The domain operation was rejected"
end
