defmodule Ankole.Errors.Framework.TransactionRequired do
  @moduledoc "Tells that an _in_tx composition function ran outside the caller's transaction."

  use Splode.Error, fields: [:operation], class: :framework

  def message(%{operation: operation}),
    do: "#{inspect(operation)} requires the transaction of its calling generic action"
end
