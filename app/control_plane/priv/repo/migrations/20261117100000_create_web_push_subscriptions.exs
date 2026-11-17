defmodule Ankole.Repo.Migrations.CreateWebPushSubscriptions do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE web_push_subscriptions (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      endpoint text NOT NULL,
      principal_uid text NOT NULL,
      p256dh text NOT NULL,
      auth text NOT NULL,
      user_agent text,
      inserted_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT web_push_subscriptions_pkey PRIMARY KEY (tenant_id, endpoint),
      CONSTRAINT web_push_subscriptions_endpoint_https
        CHECK (endpoint LIKE 'https://%' AND length(endpoint) <= 2048),
      CONSTRAINT web_push_subscriptions_principal_uid_fkey
        FOREIGN KEY (tenant_id, principal_uid)
        REFERENCES principals(tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE
    )
    """)

    execute(
      "CREATE INDEX web_push_subscriptions_principal_index ON web_push_subscriptions (tenant_id, principal_uid)"
    )

    execute(
      "COMMENT ON TABLE web_push_subscriptions IS 'Browser Web Push subscriptions that deliver Pod notifications to a Human.'"
    )

    execute("""
    ALTER TABLE conversation_participants
      ADD COLUMN notified_seq bigint DEFAULT 0 NOT NULL
    """)

    # Messages that existed before Web Push count as notified, so the first delivery sends no old message.
    execute("""
    UPDATE conversation_participants AS participant
    SET notified_seq = conversation.last_notifiable_seq
    FROM conversations AS conversation
    WHERE conversation.tenant_id = participant.tenant_id
      AND conversation.id = participant.conversation_id
      AND conversation.last_notifiable_seq > 0
    """)
  end

  def down do
    execute("ALTER TABLE conversation_participants DROP COLUMN notified_seq")
    execute("DROP TABLE web_push_subscriptions")
  end
end
