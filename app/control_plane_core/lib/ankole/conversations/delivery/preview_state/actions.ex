defmodule Ankole.Conversations.Delivery.PreviewState.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Conversations.Delivery.PreviewState`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Conversations.Delivery.PreviewStates

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:record_provider_message, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      PreviewStates.record_provider_message_in_tx(
        Ankole.Repo,
        args.signal_id,
        args.provider_message_id,
        args.provider_thread_id
      )
    )
  end

  defp action(:put_checkpoint, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      PreviewStates.put_checkpoint_by_id_in_tx(
        Ankole.Repo,
        args.signal_id,
        args.checkpoint,
        args.source
      )
    )
  end

  defp action(:update_checkpoint, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      PreviewStates.update_checkpoint_in_tx(
        Ankole.Repo,
        args.signal_id,
        args.update
      )
    )
  end

  defp action(:prepare_mutation, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      PreviewStates.prepare_mutation_in_tx(
        Ankole.Repo,
        args.signal_id,
        args.purpose,
        args.actions_digest,
        args.uuid
      )
    )
  end

  defp action(:claim_owner, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Delivery.Preview.claim_owner_in_tx(
        Ankole.Repo,
        args.signal_id,
        args.subject_uid,
        args.conversation_id,
        args.stream_signal_id,
        args.opts
      )
    )
  end

  defp action(:authorize_owner, %{arguments: args}, _context) do
    case Ankole.Conversations.Delivery.Preview.authorize_owner_in_tx(Ankole.Repo, args.opts) do
      :ok -> {:ok, :authorized}
      error -> Ankole.Errors.wrap(error)
    end
  end

  defp action(:switch_owner, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Delivery.Preview.switch_owner_in_tx(
        Ankole.Repo,
        args.state,
        args.new_owner,
        args.handoff
      )
    )
  end

  defp action(:checkpoint_presentation, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Delivery.Preview.checkpoint_presentation_in_tx(
        Ankole.Repo,
        args.state,
        args.presentation
      )
    )
  end

  defp action(:wake_blocked, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      PreviewStates.wake_blocked_in_tx(
        Ankole.Repo,
        args.agent_uid,
        args.binding_name
      )
    )
  end
end
