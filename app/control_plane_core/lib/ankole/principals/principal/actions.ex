defmodule Ankole.Principals.Principal.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Principals.Principal`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Principals.Principal

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:update_human, input, _context) do
    Ankole.Principals.update_human_in_tx(input.arguments)
    |> Ankole.Errors.not_found([:not_found, :principal_not_found], Principal)
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end

  defp action(:create_local_user, input, _context) do
    Ankole.Principals.create_local_user_in_tx(input.arguments)
    |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
  end
end
