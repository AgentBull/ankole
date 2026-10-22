defmodule Ankole.Errors.Framework.NestedOperation do
  @moduledoc """
  Tells that a generic action started inside a transaction or inside another
  generic action. A generic action owns its transaction, so it must be the
  top-level call.
  """

  use Splode.Error, fields: [:resource, :action], class: :framework

  def message(%{resource: resource, action: action}),
    do:
      "#{inspect(resource)}.#{action} must run at the top level; " <>
        "use the _in_tx composition function inside another transaction"
end
