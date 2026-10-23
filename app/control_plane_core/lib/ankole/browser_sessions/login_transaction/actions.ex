defmodule Ankole.BrowserSessions.LoginTransaction.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.BrowserSessions.LoginTransaction`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:begin_login, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.begin_login_in_tx(
        args.browser_ref,
        args.purpose,
        args.request,
        args.opts
      )
    )
  end

  defp action(:bind_provider, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.bind_provider_in_tx(
        args.browser_ref,
        args.id,
        args.provider_id,
        args.state,
        args.redirect_uri
      )
    )
  end

  defp action(:put_password_ticket, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.put_password_ticket_in_tx(
        args.browser_ref,
        args.id,
        args.ticket
      )
    )
  end

  defp action(:complete_login, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.complete_login_in_tx(
        args.browser_ref,
        args.id,
        args.auth,
        args.before_commit
      )
    )
  end

  defp action(:complete_site_login, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.complete_site_login_in_tx(
        args.browser_ref,
        args.id,
        args.provider_id,
        args.proof
      )
    )
  end

  defp action(:select_authorization, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.select_authorization_in_tx(
        args.browser_ref,
        args.id,
        args.authentication_ref
      )
    )
  end

  defp action(:consume_authorization, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.consume_authorization_in_tx(
        args.browser_ref,
        args.id,
        args.authentication_ref,
        args.issue
      )
    )
  end

  defp action(:consume_login, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.BrowserSessions.consume_login_in_tx(
        args.browser_ref,
        args.id,
        args.purpose,
        args.complete
      )
    )
  end
end
