defmodule Ankole.Repo.Migrations.AddDriveVfs do
  use Ecto.Migration

  def change do
    # Knowledge data migrations call the current Pod resources, so their
    # projection columns must exist before those migrations run.
    alter table(:drive_nodes) do
      add :last_vfs_req_id, :uuid
      add :last_vfs_etag, :text
    end

    alter table(:pages) do
      add :vfs_md_size, :bigint
      add :vfs_md_blake3, :text
    end
  end
end
