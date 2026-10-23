defmodule Ankole.OIDC.RefreshTokenFamily.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.RefreshTokenFamily`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:revoke_family, %{arguments: args}, _context),
    do: {:ok, Ankole.OIDC.RefreshStore.revoke_family_in_tx(args.id)}
end
