defmodule Ankole.Authn.Error do
  @moduledoc "A rejected authentication or credential operation."
  use Splode.Error, fields: [:reason], class: :invalid

  def login(reason) when is_exception(reason), do: {:error, reason}
  def login(reason), do: {:error, exception(reason: reason)}
  def message(%{reason: reason}), do: inspect(reason)
end
