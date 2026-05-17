defmodule BullX.EventBus.InvalidEvent do
  @moduledoc """
  EventBus input validation error.

  Details must remain safe to log. Do not place Event payloads or provider raw
  data in this struct.
  """

  @enforce_keys [:code, :path, :message]
  defstruct [:code, :path, :message, details: %{}]

  @type path_part :: String.t() | non_neg_integer()

  @type t :: %__MODULE__{
          code: atom(),
          path: [path_part()],
          message: String.t(),
          details: map()
        }
end
