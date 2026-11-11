defmodule Ankole.Repo.Migrations.IndexFileObjectsBySha256 do
  use Ecto.Migration

  # Pod looks up the objects that hold the same bytes as a scanned PDF, so that
  # it sends those bytes to OCR once in a tenant.
  def change do
    create index(:file_objects, [:tenant_id, :sha256], where: "sha256 IS NOT NULL")
  end
end
