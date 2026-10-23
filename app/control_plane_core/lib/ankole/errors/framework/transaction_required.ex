defmodule Ankole.Errors.Framework.TransactionRequired do
  @moduledoc "Tells that an _in_tx composition function ran outside the caller's transaction."

  use Splode.Error, fields: [:operation], class: :framework

  def message(%{operation: operation}),
    do: "#{inspect(operation)} requires the transaction of its calling generic action"

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
