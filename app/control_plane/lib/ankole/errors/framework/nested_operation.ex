defmodule Ankole.Errors.Framework.NestedOperation do
  @moduledoc """
  Tells that a top-level operation started inside a transaction or inside
  another top-level operation. A top-level operation owns its transaction, so
  it must be the top-level call.
  """

  use Splode.Error, fields: [:resource, :action], class: :framework

  def message(%{resource: resource, action: action}),
    do:
      "#{inspect(resource)}.#{action} must run at the top level; " <>
        "use the _in_tx composition function inside another transaction"

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(error),
      do: %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 500,
        code: "something_went_wrong",
        title: "SomethingWentWrong",
        detail: "the request failed for an unexpected reason; check the server log",
        internal_description: Exception.message(error),
        log_level: :error
      }
  end
end
