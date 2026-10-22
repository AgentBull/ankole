defmodule Ankole.Conversations.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Conversations.Conversation do
      define(:get_conversation, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_conversations, action: :read)
      define(:ensure_native_conversation, action: :ensure_native)
      define(:create_external_conversation, action: :create_external)
      define(:observe_conversation, action: :observe)
      define(:put_metadata_conversation, action: :put_metadata)
      define(:touch_conversation, action: :touch)
      define(:advance_sequence_conversation, action: :advance_sequence)
      define(:set_standing_orders_conversation, action: :set_standing_orders)
      define(:remove_conversation, action: :remove)
    end

    resource Ankole.Conversations.Participant do
      define(:get_participant,
        action: :read,
        get_by: [:conversation_id, :principal_uid],
        not_found_error?: false
      )

      define(:list_participants, action: :read)
      define(:join_participant, action: :join)
    end

    resource Ankole.Conversations.Message do
      define(:get_message, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_messages, action: :read)
      define(:record_message, action: :record)
      define(:record_once_message, action: :record_once)
      define(:edit_message, action: :edit)
      define(:observe_message, action: :observe)
      define(:resolve_attachments_message, action: :resolve_attachments)
      define(:remove_message, action: :remove)
    end

    resource Ankole.Conversations.ExternalMessageRef do
      define(:get_external_message_ref,
        action: :read,
        get_by: [:message_id],
        not_found_error?: false
      )

      define(:list_external_message_refs, action: :read)
      define(:record_external_message_ref, action: :record)
      define(:observe_external_message_ref, action: :observe)
      define(:fold_reaction_external_message_ref, action: :fold_reaction)
    end

    resource Ankole.Conversations.InputTombstone do
      define(:get_input_tombstone,
        action: :read,
        get_by: [:conversation_id, :provider_message_id],
        not_found_error?: false
      )

      define(:list_input_tombstones, action: :read)
      define(:record_input_tombstone, action: :record)
      define(:expire_input_tombstone, action: :expire)
    end

    resource Ankole.Conversations.InboundBatch do
      define(:get_inbound_batch, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_inbound_batches, action: :read)
      define(:open_inbound_batch, action: :open)
      define(:replace_prefix_inbound_batch, action: :replace_prefix)
      define(:revise_inbound_batch, action: :revise)
    end

    resource Ankole.Conversations.Delivery.PreviewState do
      define(:get_preview_state, action: :read, get_by: [:signal_id], not_found_error?: false)
      define(:list_preview_states, action: :read)
      define(:ensure_preview_state, action: :ensure)
      define(:update_preview_preview_state, action: :update_preview)
    end

    resource Ankole.Conversations.Delivery.Intent do
      define(:get_intent,
        action: :read,
        get_by: [:agent_uid, :binding_name, :outbound_key],
        not_found_error?: false
      )

      define(:list_intents, action: :read)
      define(:commit_intent, action: :commit)
      define(:prepare_intent, action: :prepare)
      define(:import_attachments_intent, action: :import_attachments)
      define(:link_message_intent, action: :link_message)
    end
  end
end
