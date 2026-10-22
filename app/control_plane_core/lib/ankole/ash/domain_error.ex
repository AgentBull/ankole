defmodule Ankole.Ash.DomainError do
  @moduledoc "Carries a declared domain rejection through Ash without exposing its input."

  use Splode.Error, fields: [:reason], class: :invalid

  def message(_error), do: "The domain operation was rejected"
end
