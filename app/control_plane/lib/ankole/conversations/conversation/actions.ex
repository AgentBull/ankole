defmodule Ankole.Conversations.Conversation.Actions do
  @moduledoc """
  Runs `:observe_external_conversation` on `Ankole.Conversations.Conversation`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(%{arguments: args}, _opts, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.External.observe_conversation_in_tx(
        args.binding,
        args.observation,
        args.now
      )
    )
  end
end
