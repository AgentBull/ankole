defmodule Ankole.Conversations.PostResult do
  @moduledoc "Public statements and Delivery intents committed by one post operation."
  defstruct messages: [], intents: [], signals: []

  def merge(%__MODULE__{} = left, %__MODULE__{} = right),
    do: %__MODULE__{
      messages: left.messages ++ right.messages,
      intents: left.intents ++ right.intents,
      signals: left.signals ++ right.signals
    }
end
