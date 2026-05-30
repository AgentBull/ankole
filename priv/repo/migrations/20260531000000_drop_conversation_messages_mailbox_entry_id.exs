defmodule BullX.Repo.Migrations.DropConversationMessagesMailboxEntryId do
  use Ecto.Migration

  def change do
    drop_if_exists index(:conversation_messages, [:mailbox_entry_id])

    drop_if_exists unique_index(:conversation_messages, [:mailbox_entry_id],
                     name: :conversation_messages_inbound_entry_unique_index
                   )

    alter table(:conversation_messages) do
      remove_if_exists :mailbox_entry_id, :uuid
    end

    create_if_not_exists unique_index(
                           :conversation_messages,
                           [:conversation_id, :event_source, :event_id],
                           where:
                             "event_source IS NOT NULL AND event_id IS NOT NULL AND role IN ('user', 'im_ambient') AND kind = 'normal'",
                           name: :conversation_messages_inbound_event_unique_index
                         )
  end
end
