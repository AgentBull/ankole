defmodule Ankole.OIDC.Session.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.Session`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:ensure, %{arguments: args}, _context) do
    Ankole.Errors.wrap(Ankole.OIDC.Sessions.ensure_in_tx(args.client_id, args.auth, args.scope))
  end
end
