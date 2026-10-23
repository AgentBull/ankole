defmodule Ankole.BrowserSessions.Session.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.BrowserSessions.Session`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:activate, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.activate_in_tx(
        args.browser_ref,
        args.authentication_ref,
        args.tenant_id
      )
    )
  end

  defp action(:logout, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.logout_in_tx(args.browser_ref, args.expected_revision)
    )
  end
end
