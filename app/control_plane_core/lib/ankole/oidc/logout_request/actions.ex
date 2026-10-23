defmodule Ankole.OIDC.LogoutRequest.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.LogoutRequest`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:confirm, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.RPLogout.confirm_in_tx(args.browser_ref, args.id))
end
