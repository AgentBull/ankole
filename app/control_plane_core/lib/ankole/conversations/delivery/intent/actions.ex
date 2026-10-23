defmodule Ankole.Conversations.Delivery.Intent.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Conversations.Delivery.Intent`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:claim_dispatch, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Delivery.Dispatch.claim_in_tx(
        Ankole.Repo,
        args.agent_uid,
        args.binding_name,
        args.outbound_key,
        args.adapter,
        args.now
      )
    )
  end

  defp action(:finalize_attempt, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Delivery.Dispatch.finalize_in_tx(
        Ankole.Repo,
        args.intent,
        args.phase,
        args.result,
        args.conversation,
        args.now
      )
    )
  end

  defp action(:retry_stopped, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Delivery.Recovery.requeue_in_tx(
        Ankole.Repo,
        args.agent_uid,
        args.binding_name,
        args.outbound_key,
        args.now
      )
    )
  end

  defp action(:wake_blocked, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Delivery.Recovery.wake_blocked_in_tx(
        Ankole.Repo,
        args.agent_uid,
        args.binding_name,
        args.now
      )
    )
  end
end
