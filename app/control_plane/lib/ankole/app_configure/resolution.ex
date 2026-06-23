defmodule Ankole.AppConfigure.Resolution do
  @moduledoc """
  Effective AppConfigure value with source metadata.
  """

  @enforce_keys [:value, :source]
  defstruct [:value, :source, :scope]

  @type source :: :agent | :global | :default
  @type t :: %__MODULE__{
          value: term(),
          source: source(),
          scope: String.t() | nil
        }
end
