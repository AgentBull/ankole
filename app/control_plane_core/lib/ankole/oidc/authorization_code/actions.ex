defmodule Ankole.OIDC.AuthorizationCode.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.AuthorizationCode`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:authorize, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.Grants.authorize_in_tx(args.params, args.authentication))

  defp action(:exchange, %{arguments: args}, _context) do
    Ankole.Errors.wrap(Ankole.OIDC.Grants.exchange_code_in_tx(args.client, args.code, args.grant))
  end
end
