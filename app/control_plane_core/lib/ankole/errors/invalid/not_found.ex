defmodule Ankole.Errors.Invalid.NotFound do
  @moduledoc "Tells that the operation target does not exist in the current tenant."

  use Splode.Error, fields: [:resource, :id], class: :invalid

  def message(%{resource: resource}), do: "#{inspect(resource)} was not found"
end
