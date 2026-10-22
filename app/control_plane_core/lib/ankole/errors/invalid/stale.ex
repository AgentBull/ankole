defmodule Ankole.Errors.Invalid.Stale do
  @moduledoc "Tells that a write found no current row that matches its filter."

  use Splode.Error, fields: [:resource, :filter], class: :invalid

  def message(%{resource: resource}), do: "#{inspect(resource)} changed before this write"
end
