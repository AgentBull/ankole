defmodule Ankole.OIDC.RefreshToken.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.RefreshToken`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:rotate, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.OIDC.RefreshStore.rotate_in_tx(
        args.digest,
        args.child,
        args.successor,
        args.ciphertext,
        args.now
      )
    )
  end

  defp action(:refresh, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.Grants.refresh_in_tx(args.client, args.rotated))
end
