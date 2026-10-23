defmodule Ankole.OIDC.LogoutDelivery.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.LogoutDelivery`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_retry, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.Logout.console_retry_in_tx(args.client_id, args.id))

  defp action(:retry, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.Logout.retry_in_tx(args.id))

  defp action(:claim, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.Logout.claim_in_tx(args.id))
end
