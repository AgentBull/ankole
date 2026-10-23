defmodule Ankole.Setup.Operations.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Setup.Operations`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:complete, %{arguments: args}, _context) do
    Ankole.Repo
    |> Ankole.Setup.Completion.complete_in_tx(args.principal_uid, args.brain_packs)
    |> Ankole.Errors.wrap()
  end
end
