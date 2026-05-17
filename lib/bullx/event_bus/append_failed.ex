defmodule BullX.EventBus.AppendFailed do
  @moduledoc """
  Runtime handoff error after a non-Blackhole Event Routing Rule matched.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
end
