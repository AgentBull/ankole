defmodule Ankole.Repo.Migrations.CreatePodAppletApprovals do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE pod_applet_approvals (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      page_id uuid NOT NULL,
      request_key text NOT NULL,
      requester_uid text NOT NULL,
      reviewer_uid text NOT NULL,
      summary text NOT NULL,
      details text,
      status text NOT NULL DEFAULT 'pending',
      decided_at timestamptz,
      note text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT pod_applet_approvals_page_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT pod_applet_approvals_reviewer_fkey
        FOREIGN KEY (tenant_id, reviewer_uid) REFERENCES principals(tenant_id, uid)
        ON DELETE RESTRICT ON UPDATE CASCADE,
      CONSTRAINT pod_applet_approvals_request_key_check
        CHECK (char_length(request_key) BETWEEN 1 AND 160 AND request_key ~ '[^[:space:]]'),
      CONSTRAINT pod_applet_approvals_summary_check
        CHECK (char_length(summary) BETWEEN 1 AND 500 AND summary ~ '[^[:space:]]'),
      CONSTRAINT pod_applet_approvals_details_check CHECK (char_length(details) <= 4000),
      CONSTRAINT pod_applet_approvals_note_check CHECK (char_length(note) <= 1000),
      CONSTRAINT pod_applet_approvals_resolution_check CHECK (
        (status = 'pending' AND decided_at IS NULL AND note IS NULL)
        OR (status IN ('approved', 'rejected') AND decided_at IS NOT NULL)
      )
    )
    """)

    create unique_index(:pod_applet_approvals, [:tenant_id, :page_id, :request_key],
             name: :pod_applet_approvals_request_index
           )
  end

  def down do
    drop table(:pod_applet_approvals)
  end
end
