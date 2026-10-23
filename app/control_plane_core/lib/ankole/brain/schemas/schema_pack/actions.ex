defmodule Ankole.Brain.Schemas.SchemaPack.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.SchemaPack`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:install_packs, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.Brain.SchemaPacks.install_packs_in_tx(Ankole.Repo, args.names))
end
