defmodule Ankole.Repo.Migrations.AddPeerConversations do
  use Ecto.Migration

  def up do
    # Principal renames reach these subtype rows and Conversations by separate
    # cascade paths. Check their typed references once both paths have settled.
    execute("""
    ALTER TABLE conversations
      ADD COLUMN dm_human_uid text,
      ADD COLUMN dm_colleague_uid text,
      ADD COLUMN origin_conversation_id uuid,
      ADD COLUMN peer_sender_uid text,
      ADD COLUMN peer_target_uid text,
      ADD COLUMN last_notifiable_seq bigint NOT NULL DEFAULT 0,
      ADD CONSTRAINT conversations_dm_human_fkey FOREIGN KEY (tenant_id, dm_human_uid)
        REFERENCES human_users(tenant_id, principal_uid) ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT conversations_dm_colleague_fkey FOREIGN KEY (tenant_id, dm_colleague_uid)
        REFERENCES agents(tenant_id, uid) ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT conversations_peer_origin_fkey FOREIGN KEY (tenant_id, origin_conversation_id)
        REFERENCES conversations(tenant_id, id) ON DELETE SET NULL (origin_conversation_id),
      ADD CONSTRAINT conversations_peer_sender_fkey FOREIGN KEY (tenant_id, peer_sender_uid)
        REFERENCES agents(tenant_id, uid) ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT conversations_peer_target_fkey FOREIGN KEY (tenant_id, peer_target_uid)
        REFERENCES agents(tenant_id, uid) ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT conversations_dm_identity_check CHECK (
        (dm_human_uid IS NULL AND dm_colleague_uid IS NULL) OR
        (dm_human_uid IS NOT NULL AND dm_colleague_uid IS NOT NULL AND
         kind = 'native' AND room_mode = 'dm' AND native_access_scope = 'participants')
      ),
      ADD CONSTRAINT conversations_peer_identity_check CHECK (
        (native_access_scope = 'agent_peer' AND peer_sender_uid IS NOT NULL AND peer_target_uid IS NOT NULL
         AND peer_sender_uid <> peer_target_uid) OR
        (native_access_scope IS DISTINCT FROM 'agent_peer' AND peer_sender_uid IS NULL
         AND peer_target_uid IS NULL AND origin_conversation_id IS NULL)
      ),
      ADD CONSTRAINT conversations_notifiable_sequence_check CHECK (
        last_notifiable_seq >= 0 AND last_notifiable_seq <= sequence_high_water
      )
    """)

    execute("ALTER TABLE conversations DROP CONSTRAINT conversations_native_room_check")

    execute("""
    ALTER TABLE conversations ADD CONSTRAINT conversations_native_room_check CHECK (
      (kind = 'native' AND room_mode IS NOT NULL AND room_mode IN ('dm', 'group')
       AND native_access_scope IS NOT NULL AND native_access_scope IN ('participants', 'anchor_page', 'agent_peer')
       AND (native_access_scope <> 'anchor_page' OR page_id IS NOT NULL)
       AND jsonb_typeof(preferred_models) = 'object') OR
      (kind = 'external' AND room_mode IS NULL AND native_access_scope IS NULL)
    )
    """)

    execute("UPDATE conversations SET last_notifiable_seq = sequence_high_water")

    execute("""
    WITH pairs AS (
      SELECT c.tenant_id, c.id, h.principal_uid AS human_uid, a.uid AS colleague_uid,
        row_number() OVER (PARTITION BY c.tenant_id, h.principal_uid, a.uid
          ORDER BY c.last_activity_at DESC, c.id DESC) AS position
      FROM conversations c
      JOIN conversation_participants hp ON hp.tenant_id = c.tenant_id AND hp.conversation_id = c.id
      JOIN human_users h ON h.tenant_id = hp.tenant_id AND h.principal_uid = hp.principal_uid
      JOIN conversation_participants ap ON ap.tenant_id = c.tenant_id AND ap.conversation_id = c.id AND ap.role = 'agent'
      JOIN agents a ON a.tenant_id = ap.tenant_id AND a.uid = ap.principal_uid AND a.type = 'ai_colleague'
      WHERE c.kind = 'native' AND c.room_mode = 'dm' AND c.native_access_scope = 'participants'
        AND hp.role IN ('owner', 'member')
        AND (SELECT count(*) FROM conversation_participants p
          WHERE p.tenant_id = c.tenant_id AND p.conversation_id = c.id AND p.role <> 'observer') = 2
    )
    UPDATE conversations c SET dm_human_uid = p.human_uid, dm_colleague_uid = p.colleague_uid
      FROM pairs p WHERE p.tenant_id = c.tenant_id AND p.id = c.id AND p.position = 1
    """)

    execute("""
    CREATE UNIQUE INDEX conversations_dm_identity_index ON conversations
      (tenant_id, dm_human_uid, dm_colleague_uid) WHERE dm_human_uid IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX conversations_peer_identity_index ON conversations
      (tenant_id, origin_conversation_id, peer_sender_uid, peer_target_uid)
      WHERE native_access_scope = 'agent_peer' AND origin_conversation_id IS NOT NULL
    """)
  end

  def down, do: raise(Ecto.MigrationError, "forward-only conversation identity migration")
end
