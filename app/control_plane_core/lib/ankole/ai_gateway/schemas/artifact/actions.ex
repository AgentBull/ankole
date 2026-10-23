defmodule Ankole.AIGateway.Schemas.Artifact.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.AIGateway.Schemas.Artifact`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:persist_output, input, _context) do
    input.arguments
    |> Ankole.AIGateway.ImageStreamPersistence.persist_output()
    |> Ankole.Errors.wrap()
  end
end
