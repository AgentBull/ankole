defmodule Ankole.Repo.Migrations.AddActionCardsAndFileComments do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE page_comments
      DROP CONSTRAINT page_comments_page_fkey,
      ADD CONSTRAINT page_comments_page_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES drive_nodes(tenant_id, id) ON DELETE CASCADE,
      ADD COLUMN anchor jsonb,
      DROP CONSTRAINT page_comments_root_shape,
      DROP CONSTRAINT page_comments_anchor_shape,
      ADD CONSTRAINT page_comments_root_shape CHECK (
        root_id IS NULL
        OR (
          root_id <> id
          AND quote IS NULL
          AND anchor_revision IS NULL
          AND anchor IS NULL
          AND resolved_at IS NULL
        )
      ),
      ADD CONSTRAINT page_comments_anchor_shape CHECK (
        (
          anchor IS NULL
          AND (quote IS NULL) = (anchor_revision IS NULL)
          AND (anchor_revision IS NULL OR anchor_revision >= 0)
        )
        OR (
          anchor IS NOT NULL
          AND root_id IS NULL
          AND anchor_revision IS NULL
          AND jsonb_typeof(anchor) = 'object'
          AND octet_length(anchor::text) <= 1024
          AND (quote IS NULL OR (char_length(quote) <= 1000 AND octet_length(quote) <= 4096))
        )
      )
    """)

    execute("""
    ALTER TABLE page_user_states
      DROP CONSTRAINT page_user_states_tenant_id_page_id_fkey,
      ADD CONSTRAINT page_user_states_tenant_id_page_id_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES drive_nodes(tenant_id, id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE conversations
      DROP CONSTRAINT conversations_page_fkey,
      ADD CONSTRAINT conversations_page_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES drive_nodes(tenant_id, id) ON DELETE SET NULL (page_id)
    """)

    execute("""
    CREATE TABLE conversation_action_cards (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      conversation_id uuid NOT NULL,
      session_id text NOT NULL,
      agent_uid text NOT NULL,
      source_signal_id uuid NOT NULL,
      interaction_id text NOT NULL,
      action_kind text NOT NULL,
      summary text NOT NULL,
      target_node_id uuid,
      payload jsonb NOT NULL DEFAULT '{}'::jsonb,
      preconditions jsonb NOT NULL DEFAULT '{}'::jsonb,
      status text NOT NULL DEFAULT 'prepared',
      resolved_by_uid text,
      resolved_by_name text,
      resolved_at timestamptz,
      resolution_note text,
      notified_senders jsonb NOT NULL DEFAULT '[]'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT conversation_action_cards_conversation_fkey
        FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT conversation_action_cards_signal_fkey
        FOREIGN KEY (tenant_id, source_signal_id) REFERENCES signals(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT conversation_action_cards_status_check
        CHECK (status IN ('prepared', 'executed', 'stale', 'cancelled')),
      CONSTRAINT conversation_action_cards_action_kind_check
        CHECK (action_kind IN (
          'pod.page.set_sharing',
          'pod.page.delete',
          'pod.page.restore',
          'pod.base.delete_table',
          'conversation.add_participants'
        )),
      CONSTRAINT conversation_action_cards_summary_check
        CHECK (char_length(summary) BETWEEN 1 AND 500 AND summary ~ '[^[:space:]]'),
      CONSTRAINT conversation_action_cards_resolution_shape
        CHECK ((status = 'prepared' AND resolved_at IS NULL) OR (status <> 'prepared' AND resolved_at IS NOT NULL)),
      CONSTRAINT conversation_action_cards_notified_senders_shape
        CHECK (jsonb_typeof(notified_senders) = 'array')
    )
    """)

    execute("""
    CREATE UNIQUE INDEX conversation_action_cards_signal_interaction_index
      ON conversation_action_cards(tenant_id, source_signal_id, interaction_id)
    """)

    execute("""
    CREATE INDEX conversation_action_cards_conversation_status_index
      ON conversation_action_cards(tenant_id, conversation_id, status)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS conversation_action_cards")

    execute("""
    ALTER TABLE conversations
      DROP CONSTRAINT IF EXISTS conversations_page_fkey,
      ADD CONSTRAINT conversations_page_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE SET NULL (page_id)
    """)

    execute("""
    ALTER TABLE page_user_states
      DROP CONSTRAINT IF EXISTS page_user_states_tenant_id_page_id_fkey,
      ADD CONSTRAINT page_user_states_tenant_id_page_id_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE page_comments
      DROP CONSTRAINT IF EXISTS page_comments_anchor_shape,
      DROP CONSTRAINT IF EXISTS page_comments_root_shape,
      DROP COLUMN IF EXISTS anchor,
      DROP CONSTRAINT IF EXISTS page_comments_page_fkey,
      ADD CONSTRAINT page_comments_page_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE,
      ADD CONSTRAINT page_comments_root_shape CHECK (
        root_id IS NULL
        OR (
          root_id <> id
          AND quote IS NULL
          AND anchor_revision IS NULL
          AND resolved_at IS NULL
        )
      ),
      ADD CONSTRAINT page_comments_anchor_shape CHECK (
        (quote IS NULL) = (anchor_revision IS NULL)
        AND (anchor_revision IS NULL OR anchor_revision >= 0)
      )
    """)
  end
end
