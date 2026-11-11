defmodule Ankole.Repo.Migrations.CreateConnectorAuthWaits do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE connector_auth_waits (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      signal_id uuid NOT NULL,
      conversation_id uuid NOT NULL,
      agent_uid text NOT NULL,
      human_uid text,
      auth_config_id uuid,
      connection_slug text NOT NULL,
      plugin_id text,
      toolkit text NOT NULL,
      tool_name text,
      subject_kind text NOT NULL DEFAULT 'human',
      required_scopes text[] NOT NULL DEFAULT '{}',
      authorization_url text NOT NULL,
      interaction_id text,
      status text NOT NULL DEFAULT 'recorded',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT connector_auth_waits_signal_fkey
        FOREIGN KEY (tenant_id, signal_id) REFERENCES signals(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT connector_auth_waits_conversation_fkey
        FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT connector_auth_waits_agent_fkey
        FOREIGN KEY (tenant_id, agent_uid) REFERENCES principals(tenant_id, uid)
        ON DELETE CASCADE ON UPDATE CASCADE,
      CONSTRAINT connector_auth_waits_human_fkey
        FOREIGN KEY (tenant_id, human_uid) REFERENCES principals(tenant_id, uid)
        ON DELETE CASCADE ON UPDATE CASCADE,
      CONSTRAINT connector_auth_waits_auth_config_fkey
        FOREIGN KEY (tenant_id, auth_config_id) REFERENCES connector_auth_configs(tenant_id, id)
        ON DELETE SET NULL,
      CONSTRAINT connector_auth_waits_subject_kind_check
        CHECK (subject_kind IN ('human', 'app')),
      CONSTRAINT connector_auth_waits_status_check
        CHECK (status IN ('recorded', 'pending', 'completed', 'superseded'))
    )
    """)

    create unique_index(
             :connector_auth_waits,
             [:tenant_id, :signal_id, :connection_slug, :subject_kind],
             name: :connector_auth_waits_signal_slug_uidx
           )

    execute("""
    CREATE INDEX connector_auth_waits_pending_idx
      ON connector_auth_waits (tenant_id, human_uid, auth_config_id)
      WHERE status = 'pending'
    """)

    execute("""
    CREATE INDEX connector_auth_waits_pending_slug_idx
      ON connector_auth_waits (tenant_id, connection_slug)
      WHERE status = 'pending'
    """)
  end

  def down do
    drop table(:connector_auth_waits)
  end
end
