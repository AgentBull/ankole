defmodule Ankole.Errors.Invalid.StatusTransition do
  @moduledoc "Tells that the state machine of a resource does not permit a transition."

  use Splode.Error, fields: [:resource, :field, :from, :to], class: :invalid

  def message(%{from: from, to: to}),
    do: "the state machine does not permit #{inspect(from)} to #{inspect(to)}"

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(_error),
      do: %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 409,
        code: "conflict",
        title: "Conflict",
        detail: "the resource changed or does not permit this change; reload it and try again"
      }
  end
end
