defmodule Ankole.AIGateway.Domain do
  @moduledoc "Durable AIGateway artifacts and provider usage."
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AIGateway.Schemas.Artifact do
      define(:get_artifact, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_artifacts, action: :read)
      define(:upload_artifact, action: :upload)
      define(:generate_image_artifact, action: :generate_image)
      define(:remove_artifact, action: :remove)
      define(:collect_artifact, action: :collect)
    end

    resource Ankole.AIGateway.Schemas.CompactionArtifact do
      define(:get_compaction_artifact, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_compaction_artifacts, action: :read)
      define(:store_compaction_artifact, action: :store)
    end

    resource Ankole.AIGateway.Schemas.UsageRecord do
      define(:get_usage_record, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_usage_records, action: :read)
      define(:record_round_usage_record, action: :record_round)
    end

    resource Ankole.AIGateway.Schemas.Conversation do
      define(:get_conversation, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_conversations, action: :read)
      define(:open_conversation, action: :open)
      define(:ensure_conversation, action: :ensure)
      define(:touch_conversation, action: :touch)
      define(:finish_conversation, action: :finish)
    end

    resource Ankole.AIGateway.Schemas.Message do
      define(:get_message, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_messages, action: :read)
      define(:start_message, action: :start)
      define(:checkpoint_message, action: :checkpoint)
      define(:journal_message, action: :journal)
      define(:quarantine_message, action: :quarantine)
      define(:heartbeat_message, action: :heartbeat)
      define(:record_progress_message, action: :record_progress)
      define(:update_context_message, action: :update_context)
      define(:remove_suffix_message, action: :remove_suffix)
    end
  end
end
