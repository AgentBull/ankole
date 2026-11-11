defmodule Ankole.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  # An Issue is the work-item record of one native conversation. The conversation
  # holds the title, the discussion, and the Agent Session whose Background Agent
  # Jobs and Workflows are the Issue's runs. This row holds what a person
  # decides: whether the Agent has received the request, the request that starts
  # it, and whether the person has accepted the result.
  def up do
    execute """
    CREATE TABLE issues (
      tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      conversation_id uuid NOT NULL,
      status          text NOT NULL CHECK (status IN ('todo','started','done')),
      description     text NOT NULL DEFAULT '',
      agent_uid       text,
      inserted_at     timestamptz NOT NULL,
      updated_at      timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, conversation_id),
      CONSTRAINT issues_conversation_fkey FOREIGN KEY (tenant_id, conversation_id)
        REFERENCES conversations (tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT issues_agent_fkey FOREIGN KEY (tenant_id, agent_uid)
        REFERENCES principals (tenant_id, uid) ON UPDATE CASCADE ON DELETE SET NULL (agent_uid)
    )
    """

    execute "CREATE INDEX issues_agent_index ON issues (tenant_id, agent_uid)"
  end

  def down do
    execute "DROP TABLE issues"
  end
end
