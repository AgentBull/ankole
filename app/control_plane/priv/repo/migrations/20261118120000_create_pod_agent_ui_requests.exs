defmodule Ankole.Repo.Migrations.CreatePodAgentUiRequests do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE pod_agent_ui_requests (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      agent_uid text NOT NULL,
      principal_uid text NOT NULL,
      operation text NOT NULL,
      arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
      status text DEFAULT 'pending' NOT NULL,
      result jsonb,
      error text,
      inserted_at timestamp(6) without time zone NOT NULL,
      claimed_at timestamp(6) without time zone,
      completed_at timestamp(6) without time zone,
      CONSTRAINT pod_agent_ui_requests_pkey PRIMARY KEY (tenant_id, id),
      CONSTRAINT pod_agent_ui_requests_operation_check
        CHECK (operation IN ('snapshot', 'act', 'query')),
      CONSTRAINT pod_agent_ui_requests_status_check
        CHECK (status IN ('pending', 'claimed', 'done', 'failed', 'expired')),
      CONSTRAINT pod_agent_ui_requests_error_check
        CHECK (error IS NULL OR length(error) <= 4000),
      CONSTRAINT pod_agent_ui_requests_agent_fkey
        FOREIGN KEY (tenant_id, agent_uid)
        REFERENCES principals(tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE,
      CONSTRAINT pod_agent_ui_requests_principal_fkey
        FOREIGN KEY (tenant_id, principal_uid)
        REFERENCES principals(tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE INDEX pod_agent_ui_requests_pending_index
      ON pod_agent_ui_requests (tenant_id, principal_uid, inserted_at)
      WHERE status = 'pending'
    """)

    execute(
      "COMMENT ON TABLE pod_agent_ui_requests IS 'Agent operations on the Pod page that a Human has open, and what that page answered.'"
    )
  end

  def down do
    execute("DROP TABLE pod_agent_ui_requests")
  end
end
