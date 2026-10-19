defmodule Ankole.Repo.Migrations.GeneralizeDrives do
  use Ecto.Migration

  def up do
    rename table(:agent_files), to: table(:drive_files)
    execute "ALTER TABLE drive_files DROP CONSTRAINT agent_files_pkey"
    execute "ALTER TABLE drive_files ALTER COLUMN agent_uid DROP NOT NULL"

    execute """
    CREATE UNIQUE INDEX drive_files_identity_index
      ON drive_files (tenant_id, agent_uid, path) NULLS NOT DISTINCT
    """

    execute "ALTER TABLE drive_files DROP CONSTRAINT agent_files_source"

    create constraint(:drive_files, :drive_files_source,
             check: "source IN ('inbound', 'generated', 'sent', 'agent', 'console', 'pod')"
           )
  end

  def down do
    raise Ecto.MigrationError,
          "This migration cannot preserve Pod files or attachment-only messages in the old schema. " <>
            "Export or convert incompatible rows before a manual rollback."
  end
end
