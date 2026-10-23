defmodule Ankole.BrowserSessions.Authentication.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.BrowserSessions.Authentication`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:revoke, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.revoke_in_tx(args.browser_ref, args.authentication_ref)
    )
  end

  defp action(:create_pod_access, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.create_pod_access_in_tx(args.authentication_ref, args.create)
    )
  end

  defp action(:connect_pod_access, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.connect_pod_access_in_tx(
        args.authentication_ref,
        args.verified_ref,
        args.tenant_id,
        args.connect
      )
    )
  end
end
