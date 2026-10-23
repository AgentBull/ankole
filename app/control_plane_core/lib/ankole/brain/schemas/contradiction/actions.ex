defmodule Ankole.Brain.Schemas.Contradiction.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.Contradiction`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.Contradiction

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:decide, %{arguments: args}, _context) do
    args.contradiction_id
    |> Ankole.Brain.Dreaming.decide_contradiction_in_tx(args.status, args[:resolution_note])
    |> Ankole.Brain.Console.result(Contradiction)
  end
end
