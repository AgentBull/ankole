defmodule Ankole.Conversations.Conversation.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Conversations.Conversation`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:start_native, %{arguments: args}, _context) do
    Ankole.Errors.wrap(Ankole.Conversations.create_in_tx(Ankole.Repo, args.human_uid, args.attrs))
  end

  defp action(:post_native, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.post_in_tx(Ankole.Repo, args.human_uid, args.id, args.attrs)
    )
  end

  defp action(:change_native_queue, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.update_queue_in_tx(
        Ankole.Repo,
        args.human_uid,
        args.id,
        args.attrs
      )
    )
  end

  defp action(:remove_native, %{arguments: args}, _context) do
    Ankole.Errors.wrap(Ankole.Conversations.delete_in_tx(Ankole.Repo, args.human_uid, args.id))
  end

  defp action(:observe_entry, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Observe.accept_entry_in_tx(
        Ankole.Repo,
        args.binding,
        args.fact,
        args.now
      )
    )
  end

  defp action(:observe_reaction, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Observe.accept_reaction_in_tx(
        Ankole.Repo,
        args.binding,
        args.fact,
        args.now
      )
    )
  end

  defp action(:observe_action, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Observe.accept_action_in_tx(
        Ankole.Repo,
        args.binding,
        args.fact,
        args.now
      )
    )
  end

  defp action(:observe_lifecycle, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Observe.accept_lifecycle_in_tx(
        Ankole.Repo,
        args.binding,
        args.fact,
        args.now
      )
    )
  end

  defp action(:notify_held_sender, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.Observe.notify_held_sender_in_tx(Ankole.Repo, args.fact, args.now)
    )
  end

  defp action(:ensure_im_group, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.IMGroupProjection.ensure_group_in_tx(
        Ankole.Repo,
        args.group_key,
        args.attrs,
        args.context,
        args.opts
      )
    )
  end

  defp action(:update_im_group_membership, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.IMGroupProjection.update_membership_in_tx(
        Ankole.Repo,
        args.group_key,
        args.update
      )
    )
  end

  defp action(:replace_im_group_members, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.IMGroupMembers.replace_members_in_tx(
        Ankole.Repo,
        args.group_id,
        args.human_uids
      )
    )
  end

  defp action(:reconcile_im_group_agents, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.IMGroupMembers.reconcile_agent_members_in_tx(
        Ankole.Repo,
        args.group_id
      )
    )
  end

  defp action(:update_external_metadata, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.External.update_metadata_in_tx(Ankole.Repo, args.id, args.update)
    )
  end

  defp action(:observe_external_conversation, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.External.observe_conversation_in_tx(
        Ankole.Repo,
        args.binding,
        args.observation,
        args.now
      )
    )
  end

  defp action(:native_detail, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.detail_in_tx(Ankole.Repo, args.human_uid, args.id, args.opts)
    )
  end

  defp action(:select_model_profile, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.set_model_profile_in_tx(
        Ankole.Repo,
        args.human_uid,
        args.id,
        args.profile
      )
    )
  end

  defp action(:context_snapshot, %{arguments: args}, _context) do
    Ankole.Errors.wrap(
      Ankole.Conversations.context_snapshot_in_tx(
        Ankole.Repo,
        args.id,
        args.key,
        args.read_seq,
        args.excluded_ids,
        args.opts
      )
    )
  end
end
