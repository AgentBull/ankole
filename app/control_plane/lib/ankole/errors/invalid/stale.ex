defmodule Ankole.Errors.Invalid.Stale do
  @moduledoc "Tells that a write found no current row that matches its filter."

  use Splode.Error, fields: [:resource, :filter], class: :invalid

  def message(%{resource: resource}), do: "#{inspect(resource)} changed before this write"

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
