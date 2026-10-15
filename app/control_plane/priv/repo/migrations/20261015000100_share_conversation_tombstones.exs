defmodule Ankole.Repo.Migrations.ShareConversationTombstones do
  use Ecto.Migration

  def up do
    execute("""
    WITH merged AS (
      SELECT tenant_id, conversation_id, provider_message_id,
             max(tombstoned_until) AS tombstoned_until,
             min(inserted_at) AS inserted_at, max(updated_at) AS updated_at
      FROM conversation_input_tombstones
      GROUP BY tenant_id, conversation_id, provider_message_id
    )
    UPDATE conversation_input_tombstones t
    SET tombstoned_until = m.tombstoned_until,
        inserted_at = m.inserted_at, updated_at = m.updated_at
    FROM merged m
    WHERE (t.tenant_id, t.conversation_id, t.provider_message_id) =
          (m.tenant_id, m.conversation_id, m.provider_message_id);
    """)

    execute("""
    DELETE FROM conversation_input_tombstones t
    USING conversation_input_tombstones other
    WHERE (t.tenant_id, t.conversation_id, t.provider_message_id) =
          (other.tenant_id, other.conversation_id, other.provider_message_id)
      AND t.ctid < other.ctid;
    """)

    execute("""
    ALTER TABLE conversation_input_tombstones
      DROP CONSTRAINT conversation_input_tombstones_pkey,
      DROP COLUMN agent_uid,
      DROP COLUMN binding_name,
      ADD PRIMARY KEY (tenant_id, conversation_id, provider_message_id);
    """)
  end

  def down do
    raise "Shared deletion guards have no Agent owner. Restore the pre-upgrade backup."
  end
end
