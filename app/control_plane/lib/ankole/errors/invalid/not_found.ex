defmodule Ankole.Errors.Invalid.NotFound do
  @moduledoc "Tells that the operation target does not exist in the current tenant."

  use Splode.Error, fields: [:resource, :id], class: :invalid

  def message(%{resource: resource}), do: "#{inspect(resource)} was not found"

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(_error),
      do: %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 404,
        code: "not_found",
        title: "NotFound",
        detail: "the resource was not found"
      }
  end
end
