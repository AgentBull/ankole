defmodule Ankole.Repo.Migrations.MoveDeliveryPreviews do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE delivery_previews (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      signal_id uuid NOT NULL,
      provider_message_id text,
      checkpoint jsonb,
      sequence_high_water integer NOT NULL DEFAULT 0 CHECK (sequence_high_water >= 0),
      PRIMARY KEY (tenant_id, signal_id),
      FOREIGN KEY (tenant_id, signal_id) REFERENCES signals(tenant_id, id) ON DELETE CASCADE,
      CHECK (checkpoint IS NULL OR jsonb_typeof(checkpoint) = 'object')
    );
    """)

    execute("""
    INSERT INTO delivery_previews (tenant_id, signal_id, provider_message_id, checkpoint, sequence_high_water)
    SELECT tenant_id, id, reply_preview_provider_message_id, reply_preview_checkpoint, reply_preview_sequence_high_water
    FROM signals
    WHERE reply_preview_provider_message_id IS NOT NULL OR reply_preview_checkpoint IS NOT NULL
       OR reply_preview_sequence_high_water <> 0;
    """)

    execute("""
    ALTER TABLE signals DROP COLUMN reply_preview_provider_message_id,
      DROP COLUMN reply_preview_checkpoint, DROP COLUMN reply_preview_sequence_high_water;
    """)

    execute("""
    UPDATE signals SET type = 'conversation.message.removed' WHERE type = 'signal.entry.removed';
    """)
  end

  def down do
    raise "Restore the pre-upgrade backup to recover the previous Signal schema."
  end
end
