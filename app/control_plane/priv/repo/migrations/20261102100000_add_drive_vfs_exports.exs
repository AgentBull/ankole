defmodule Ankole.Repo.Migrations.AddDriveVfsExports do
  use Ecto.Migration

  def change do
    create table(:drive_vfs_exports, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :snapshot_key, :text, null: false
      add :object_id, :uuid, null: false
      add :expires_at, :timestamptz, null: false
    end

    create index(:drive_vfs_exports, [:tenant_id, :snapshot_key, :expires_at])

    execute(
      "ALTER TABLE drive_vfs_exports ADD CONSTRAINT drive_vfs_exports_object_fkey FOREIGN KEY (tenant_id,object_id) REFERENCES file_objects(tenant_id,id)",
      "ALTER TABLE drive_vfs_exports DROP CONSTRAINT drive_vfs_exports_object_fkey"
    )
  end
end
