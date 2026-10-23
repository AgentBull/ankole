defmodule Ankole.Files.Schemas.Blob.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Files.Schemas.Blob`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:collect_marked, _input, _context),
    do: Ankole.Errors.wrap(Ankole.Files.Jobs.CollectUnreferenced.remove_batch_in_tx())
end
