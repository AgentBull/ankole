defmodule Ankole.Signals.WebhookEndpoint.Actions do
  @moduledoc """
  Runs the Console generic actions of `Ankole.Signals.WebhookEndpoint`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_operator_endpoint, input, _context) do
    Ankole.Signals.Webhooks.create_operator_endpoint_in_tx(input.arguments)
    |> Ankole.Errors.wrap()
  end

  defp action(:cancel_operator_endpoint, input, _context) do
    Ankole.Signals.Webhooks.cancel_operator_endpoint_in_tx(input.arguments.id)
    |> Ankole.Errors.wrap()
  end
end
