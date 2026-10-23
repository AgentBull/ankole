defmodule Ankole.AIAgent.Library.Schemas.AgentSkill.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIAgent.Library.Schemas.AgentSkill`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:sync_catalog, input, _context),
    do: input.arguments |> Ankole.AIAgent.Library.sync_catalog() |> Ankole.Errors.wrap()
end
