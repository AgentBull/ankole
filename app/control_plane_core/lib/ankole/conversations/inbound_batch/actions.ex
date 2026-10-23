defmodule Ankole.Conversations.InboundBatch.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Conversations.InboundBatch`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:finalize_due, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.InboundBatches.finalize_due_in_tx(
        Ankole.Repo,
        args.batch_id,
        args.now
      )
    )
  end
end
