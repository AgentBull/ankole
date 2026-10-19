defmodule Ankole.Repo.Migrations.AllowNativeMessageAttachments do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_text_present"

    execute """
    ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_text_present
      CHECK (origin = 'external' OR (text IS NOT NULL AND btrim(text) <> '') OR cardinality(attachments) > 0)
    """
  end

  def down do
    raise Ecto.MigrationError,
          "This migration cannot preserve Pod files or attachment-only messages in the old schema. " <>
            "Export or convert incompatible rows before a manual rollback."
  end
end
