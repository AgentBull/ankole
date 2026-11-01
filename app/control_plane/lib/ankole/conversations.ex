defmodule Ankole.Conversations do
  @moduledoc """
  Owns conversations, participation, and committed messages.
  """
  use Ankole.Ash.Domain

  alias Ankole.Conversations.{Native, NativeQueue, NativeRoom, Queries}

  resources do
    resource Ankole.Conversations.Conversation do
      define(:get_conversation, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_conversations, action: :read)
      define(:set_standing_orders_conversation, action: :set_standing_orders)

      define(:observe_external_conversation,
        action: :observe_external_conversation,
        args: [:binding, :observation, :now]
      )
    end

    resource Ankole.Conversations.Participant do
      define(:get_participant,
        action: :read,
        get_by: [:conversation_id, :principal_uid],
        not_found_error?: false
      )

      define(:list_participants, action: :read)
    end

    resource Ankole.Conversations.Message do
      define(:get_message, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_messages, action: :read)
    end

    resource Ankole.Conversations.ExternalMessageRef do
      define(:get_external_message_ref,
        action: :read,
        get_by: [:message_id],
        not_found_error?: false
      )

      define(:list_external_message_refs, action: :read)
    end

    resource Ankole.Conversations.InputTombstone do
      define(:list_input_tombstones, action: :read)
    end

    resource(Ankole.Conversations.InboundBatch)
    resource(Ankole.Conversations.MessageAttachment)
    resource(Ankole.Conversations.DeliveryAttachment)
    resource(Ankole.Conversations.Delivery.PreviewState)
    resource(Ankole.Conversations.ActionCard)

    resource Ankole.Conversations.Delivery.Intent do
      define(:list_intents, action: :read)
    end
  end

  defdelegate teammates(actor, query \\ nil), to: NativeRoom
  defdelegate update_conversation(actor, id, attrs), to: NativeRoom, as: :update
  defdelegate manage_participants(actor, id, attrs), to: NativeRoom, as: :manage
  defdelegate find_anchor_page_conversation_id(page_id, agent_uid), to: NativeRoom

  defdelegate ensure_anchor_page_conversation_in_tx(
                actor,
                agent,
                conv_id,
                page_id,
                title_hint,
                now
              ),
              to: NativeRoom

  defdelegate list_rooms(actor, opts \\ []), to: Native
  defdelegate agents(human_uid), to: Native
  defdelegate authorize_agent(actor, uid), to: Native
  defdelegate model_profiles(human_uid, agent_uid), to: Native
  defdelegate request_context(signal), to: Native
  defdelegate visible_native_conversation(human_uid, id), to: Native
  defdelegate model_preferences(human_uid, id, agent_uid \\ nil), to: Native
  defdelegate set_model_profile(human_uid, id, profile, agent_uid \\ nil), to: Native
  defdelegate set_model_profile_in_tx(human_uid, id, profile, agent_uid \\ nil), to: Native
  defdelegate list(human_uid), to: Native
  defdelegate list_for_page(human_uid, page_id), to: Native
  defdelegate get(human_uid, id, opts \\ []), to: Native
  defdelegate detail_in_tx(human_uid, id, opts), to: Native
  defdelegate create(human_uid, attrs), to: Native
  defdelegate create_in_tx(human_uid, attrs), to: Native
  defdelegate post(human_uid, id, attrs), to: Native
  defdelegate post_in_tx(human_uid, id, attrs), to: Native
  defdelegate post_in_tx(target, statement), to: Native
  defdelegate update_queue(human_uid, id, attrs), to: NativeQueue
  defdelegate update_queue_in_tx(human_uid, id, attrs), to: NativeQueue
  defdelegate delete(human_uid, id, opts \\ []), to: Native
  defdelegate delete_in_tx(human_uid, id, opts \\ []), to: Native

  defdelegate lock_native_participants_in_tx(key, human_uids),
    to: Native,
    as: :lock_session_participants_in_tx

  defdelegate latest_native_questions(id), to: Queries

  defdelegate answer_interaction(actor, id, interaction_id, attrs),
    to: Ankole.Conversations.Delivery.Interactions,
    as: :answer_native

  defdelegate resolve_action_card(actor, id, card_id, decision),
    to: Ankole.Conversations.ActionCards,
    as: :resolve_native

  defdelegate get_browser_action_card(actor, card_id),
    to: Ankole.Conversations.ActionCards,
    as: :get_browser_card

  defdelegate resolve_browser_action_card(actor, card_id, decision),
    to: Ankole.Conversations.ActionCards,
    as: :resolve_browser_card

  defdelegate message_changed_in_tx(before_message, after_message, now), to: Queries
  defdelegate message_for_signal(event), to: Queries
  defdelegate reply_candidate_texts(signal_ids), to: Queries

  defdelegate wake_briefing_messages(conversation_id, agent_uid, max_seq, excluded_ids, limit),
    to: Queries

  defdelegate context_snapshot(id, key, read_seq, excluded_ids, opts \\ []), to: Queries
  defdelegate context_snapshot_in_tx(id, key, read_seq, excluded_ids, opts), to: Queries
  defdelegate participating_ids(uid), to: Queries

  defdelegate resolve_attachment(actor, conversation_id, message_id, position),
    to: Ankole.Conversations.Attachments,
    as: :resolve

  defdelegate read_attachment_to_file(actor, conversation_id, message_id, position, local_path),
    to: Ankole.Conversations.Attachments,
    as: :read_to_file

  defdelegate ids_for_agent_in_tx(uid), to: Queries
  defdelegate delete_for_agent_in_tx(uid), to: Queries
  defdelegate next_sequence_in_tx(conversation), to: Queries
  defdelegate expire_input_tombstones(now), to: Queries
  defdelegate lock_conversation_in_tx(id, mode \\ :update), to: Queries
end
