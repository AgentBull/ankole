defmodule Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:replace_document, input, _context),
    do: input.arguments |> Ankole.AIAgent.Library.replace_document() |> Ankole.Errors.wrap()
end
