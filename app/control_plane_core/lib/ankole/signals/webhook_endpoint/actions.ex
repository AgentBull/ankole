defmodule Ankole.Signals.WebhookEndpoint.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Signals.WebhookEndpoint`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_endpoint, input, _context) do
    Ankole.Errors.wrap(
      Ankole.Signals.Webhooks.create_endpoint_in_tx(
        Ankole.Repo,
        input.arguments.attrs,
        input.arguments.token
      )
    )
  end

  defp action(:create_operator_endpoint, input, _context) do
    Ankole.Repo
    |> Ankole.Signals.Webhooks.create_operator_endpoint_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:cancel_operator_endpoint, input, _context) do
    Ankole.Repo
    |> Ankole.Signals.Webhooks.cancel_operator_endpoint_in_tx(input.arguments.id)
    |> Ankole.Errors.wrap()
  end

  defp action(:cancel_endpoint, input, _context) do
    args = input.arguments

    Ankole.Errors.wrap(
      Ankole.Signals.Webhooks.cancel_endpoint_in_tx(
        Ankole.Repo,
        args.agent_uid,
        args.session_id,
        args.endpoint_id,
        args.now
      )
    )
  end

  defp action(:receive, input, _context) do
    args = input.arguments

    Ankole.Errors.wrap(
      Ankole.Signals.Webhooks.receive_in_tx(
        Ankole.Repo,
        args.token,
        args.format,
        args.input,
        args.now
      )
    )
  end
end
