defmodule Ankole.Errors.Invalid.StatusTransition do
  @moduledoc "Tells that the state machine of a resource does not permit a transition."

  use Splode.Error, fields: [:resource, :field, :from, :to], class: :invalid

  def message(%{from: from, to: to}),
    do: "the state machine does not permit #{inspect(from)} to #{inspect(to)}"
end
