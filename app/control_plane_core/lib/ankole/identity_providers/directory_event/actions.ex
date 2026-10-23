defmodule Ankole.IdentityProviders.DirectoryEvent.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.IdentityProviders.DirectoryEvent`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:receive, input, _context) do
    Ankole.IdentityProviders.DirectoryAccess.receive_event_in_tx(
      Ankole.Repo,
      input.arguments.provider_id,
      input.arguments.attrs
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:apply_restriction, input, _context) do
    Ankole.IdentityProviders.DirectoryAccess.apply_restriction_in_tx(
      Ankole.Repo,
      input.arguments.event
    )
    |> Ankole.Errors.wrap()
  end

  defp action(:update_open, input, _context) do
    Ankole.IdentityProviders.DirectoryAccess.update_open_event_in_tx(
      input.arguments.event,
      input.arguments.action,
      input.arguments.attrs,
      input.arguments.only_open?
    )
    |> Ankole.Errors.wrap()
  end
end
