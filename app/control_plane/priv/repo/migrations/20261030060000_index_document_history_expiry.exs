defmodule Ankole.Repo.Migrations.IndexDocumentHistoryExpiry do
  use Ecto.Migration

  def change do
    create index(:page_snapshots, [:tenant_id, :created_at])
  end
end
