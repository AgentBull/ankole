defmodule Ankole.Repo.Migrations.UpgradePodChatMultiplayer do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE conversations
      ADD COLUMN room_mode text,
      ADD COLUMN native_access_scope text,
      ADD COLUMN title_customized boolean NOT NULL DEFAULT false,
      ADD COLUMN preferred_models jsonb NOT NULL DEFAULT '{}'::jsonb
    """)

    execute("""
    WITH counts AS (
      SELECT
        cp.tenant_id,
        cp.conversation_id,
        COUNT(*) FILTER (WHERE cp.role IN ('owner', 'member')) AS human_count,
        COUNT(*) FILTER (WHERE cp.role = 'agent') AS agent_count,
        MAX(cp.principal_uid) FILTER (WHERE cp.role = 'agent') AS primary_agent_uid
      FROM conversation_participants cp
      GROUP BY cp.tenant_id, cp.conversation_id
    )
    UPDATE conversations c
    SET
      room_mode = CASE
        WHEN COALESCE(cnt.human_count, 0) <= 1 AND COALESCE(cnt.agent_count, 0) <= 1 THEN 'dm'
        ELSE 'group'
      END,
      native_access_scope = 'participants',
      metadata = (c.metadata - 'model_profile' - 'queue_paused' - 'queue_pause_command_id') || CASE
        WHEN cnt.primary_agent_uid IS NOT NULL THEN
          jsonb_build_object('queue_paused:' || cnt.primary_agent_uid, COALESCE(c.metadata->'queue_paused', 'false'::jsonb)) ||
          CASE WHEN c.metadata ? 'queue_pause_command_id' THEN jsonb_build_object('queue_pause_command_id:' || cnt.primary_agent_uid, c.metadata->'queue_pause_command_id') ELSE '{}'::jsonb END
        ELSE '{}'::jsonb END,
      preferred_models = CASE
        WHEN c.metadata->>'model_profile' IS NOT NULL
             AND btrim(c.metadata->>'model_profile') <> ''
             AND cnt.primary_agent_uid IS NOT NULL
        THEN jsonb_build_object(cnt.primary_agent_uid, c.metadata->>'model_profile')
        ELSE '{}'::jsonb
      END
    FROM counts cnt
    WHERE c.kind = 'native'
      AND cnt.tenant_id = c.tenant_id
      AND cnt.conversation_id = c.id
    """)

    execute("""
    UPDATE conversations
    SET room_mode = 'dm', native_access_scope = 'participants'
    WHERE kind = 'native' AND room_mode IS NULL
    """)

    execute("""
    ALTER TABLE conversations
      ADD CONSTRAINT conversations_native_room_check CHECK (
        (
          kind = 'native'
          AND room_mode IS NOT NULL
          AND room_mode IN ('dm', 'group')
          AND native_access_scope IS NOT NULL
          AND native_access_scope IN ('participants', 'anchor_page')
          AND (native_access_scope = 'participants' OR page_id IS NOT NULL)
          AND jsonb_typeof(preferred_models) = 'object'
        )
        OR (
          kind = 'external'
          AND room_mode IS NULL
          AND native_access_scope IS NULL
        )
      )
    """)

    execute("""
    ALTER TABLE conversation_participants
      ADD COLUMN may_intervene boolean NOT NULL DEFAULT false,
      ADD COLUMN pinned_at timestamptz,
      ADD COLUMN muted boolean NOT NULL DEFAULT false,
      ADD COLUMN last_read_seq bigint NOT NULL DEFAULT 0
    """)

    execute(
      "ALTER TABLE conversation_participants DROP CONSTRAINT conversation_participants_role_check"
    )

    execute(
      "ALTER TABLE conversation_participants ADD CONSTRAINT conversation_participants_role_check CHECK (role IN ('owner', 'member', 'agent', 'observer'))"
    )

    execute("""
    UPDATE conversation_participants cp
    SET
      may_intervene = (cp.role = 'agent'),
      last_read_seq = CASE
        WHEN cp.role IN ('owner', 'member') THEN COALESCE(c.sequence_high_water, 0)
        ELSE 0
      END
    FROM conversations c
    WHERE c.tenant_id = cp.tenant_id AND c.id = cp.conversation_id
    """)

    execute("""
    ALTER TABLE conversation_messages
      ADD COLUMN author_display_name text,
      ADD COLUMN delivery_key text NOT NULL DEFAULT 'final'
    """)

    execute("""
    UPDATE conversation_messages m
    SET author_display_name = COALESCE(
      NULLIF(btrim(p.display_name), ''),
      CASE WHEN m.author_type = 'agent' THEN 'Archived Agent' ELSE 'Former Member' END
    )
    FROM principals p
    WHERE m.origin = 'native'
      AND p.tenant_id = m.tenant_id
      AND p.uid = m.author_uid
    """)

    execute("""
    UPDATE conversation_messages
    SET author_display_name = CASE
      WHEN author_type = 'agent' THEN 'Archived Agent'
      ELSE 'Former Member'
    END
    WHERE origin = 'native' AND (author_display_name IS NULL OR btrim(author_display_name) = '')
    """)

    execute("DROP INDEX IF EXISTS conversation_messages_signal_index")

    execute("""
    CREATE UNIQUE INDEX conversation_messages_signal_index
      ON conversation_messages (tenant_id, conversation_id, signal_id, delivery_key)
      WHERE signal_id IS NOT NULL AND origin = 'native'
    """)

    execute(
      "ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_provenance_check"
    )

    execute("""
    ALTER TABLE conversation_messages
      ADD CONSTRAINT conversation_messages_provenance_check CHECK (
        btrim(delivery_key) <> ''
        AND (
          (
            origin = 'native'
            AND author_display_name IS NOT NULL
            AND btrim(author_display_name) <> ''
            AND (
              (author_type = 'human' AND signal_id IS NULL AND session_id IS NULL)
              OR (author_type = 'agent' AND session_id IS NOT NULL AND btrim(session_id) <> '')
            )
          )
          OR origin = 'external'
        )
      )
    """)

    execute("""
    CREATE INDEX conversation_messages_native_text_trgm_idx
      ON conversation_messages USING gin (text gin_trgm_ops)
      WHERE origin = 'native'
    """)
  end

  def down do
    raise Ecto.MigrationError, "forward-only multiplayer Pod Chat migration"
  end
end
