defmodule Ankole.Repo.Migrations.AddIssueLabelsParentsAndSquads do
  use Ecto.Migration

  # People sort Issues with labels, break an Issue into sub-Issues, and name the
  # AI colleagues among whom a personal assistant shares an Issue's work. A
  # sub-Issue outlives its parent: deleting the parent's room clears the link.
  def up do
    execute """
    ALTER TABLE issues
      ADD COLUMN labels text[] NOT NULL DEFAULT '{}',
      ADD COLUMN parent_id uuid,
      ADD COLUMN squad_uids text[] NOT NULL DEFAULT '{}',
      ADD CONSTRAINT issues_labels_check CHECK (cardinality(labels) <= 10),
      ADD CONSTRAINT issues_squad_check CHECK (cardinality(squad_uids) <= 10),
      ADD CONSTRAINT issues_parent_check CHECK (parent_id IS DISTINCT FROM conversation_id),
      ADD CONSTRAINT issues_parent_fkey FOREIGN KEY (tenant_id, parent_id)
        REFERENCES issues (tenant_id, conversation_id) ON DELETE SET NULL (parent_id)
    """

    execute "CREATE INDEX issues_parent_index ON issues (tenant_id, parent_id)"
  end

  def down do
    execute "DROP INDEX issues_parent_index"

    execute """
    ALTER TABLE issues
      DROP CONSTRAINT issues_parent_fkey,
      DROP CONSTRAINT issues_parent_check,
      DROP CONSTRAINT issues_squad_check,
      DROP CONSTRAINT issues_labels_check,
      DROP COLUMN squad_uids,
      DROP COLUMN parent_id,
      DROP COLUMN labels
    """
  end
end
