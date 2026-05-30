defmodule BullX.Repo.Migrations.AddConversationMessageGenerationLookupIndexes do
  use Ecto.Migration

  def change do
    create index(
             :conversation_messages,
             ["((metadata->'generation'->>'trigger_message_id'))", :inserted_at, :id],
             where:
               "NOT (metadata ? 'transcript_effect') AND (metadata->'generation'->>'trigger_message_id') IS NOT NULL",
             name: :conversation_messages_generation_trigger_lookup_idx
           )

    create index(
             :conversation_messages,
             ["((metadata->'generation'->>'root_assistant_message_id'))"],
             where:
               "role = 'tool' AND kind = 'normal' AND NOT (metadata ? 'transcript_effect') AND (metadata->'generation'->>'root_assistant_message_id') IS NOT NULL",
             name: :conversation_messages_generation_root_assistant_idx
           )
  end
end
