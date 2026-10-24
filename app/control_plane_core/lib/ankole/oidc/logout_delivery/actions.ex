defmodule Ankole.OIDC.LogoutDelivery.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.LogoutDelivery`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(%{action: %{name: :console_retry}, arguments: args}, _opts, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.Logout.console_retry_in_tx(args.client_id, args.id))
end
