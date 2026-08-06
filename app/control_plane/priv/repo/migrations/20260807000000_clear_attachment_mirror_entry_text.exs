defmodule Ankole.Repo.Migrations.ClearAttachmentMirrorEntryText do
  use Ecto.Migration

  # Reply-attachment mirrors used to copy the complete final answer as their
  # text, so the channel archive held the same answer once per attachment and
  # once for the reply. New attachment mirrors carry the file alone; this
  # brings the stored rows to the same shape. The succeeded attachment outbox
  # rows identify the mirrors, so a final reply that shares the ai_message_id
  # keeps its text.
  def up do
    execute("""
    UPDATE signal_gateway_entries AS entry
    SET text = NULL
    FROM signal_gateway_outbox_entries AS outbox
    WHERE outbox.outbound_key LIKE 'ai-reply-attachment:%'
      AND outbox.status = 'succeeded'
      AND outbox.created_source_entry_id IS NOT NULL
      AND entry.signal_channel_id = outbox.signal_channel_id
      AND entry.source_entry_id = outbox.created_source_entry_id
    """)
  end

  # The duplicated text is not restorable and has no reader.
  def down do
    :ok
  end
end
