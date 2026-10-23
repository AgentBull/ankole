defmodule Ankole.OIDC.Client.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.OIDC.Client`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_create, input, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.console_create_in_tx(input.arguments))

  defp action(:console_update, input, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.console_update_in_tx(input.arguments))

  defp action(:console_delete, input, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.console_delete_in_tx(input.arguments.id))

  defp action(:create_client, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.create_client_in_tx(args.attrs, args.group_ids))

  defp action(:update_client, %{arguments: args}, _context),
    do: Ankole.Errors.wrap(Ankole.OIDC.update_client_in_tx(args.id, args.attrs))
end
