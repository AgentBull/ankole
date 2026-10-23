defmodule Ankole.Errors.Invalid.Stale do
  @moduledoc """
  Tells that a write found no current row that matches its filter.

  A domain can give the `reason` of the conflict, for example
  `:content_hash_conflict`. `Ankole.Errors.reason/1` gives it back, and the v2
  JSON:API error uses it as the code.
  """

  use Splode.Error, fields: [:resource, :filter, :reason], class: :invalid

  def message(%{resource: resource}), do: "#{inspect(resource)} changed before this write"

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(error),
      do: %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 409,
        code: if(error.reason, do: Atom.to_string(error.reason), else: "conflict"),
        title: "Conflict",
        detail: "the resource changed or does not permit this change; reload it and try again"
      }
  end
end
