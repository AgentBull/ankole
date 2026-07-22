defmodule Ankole.Repo.Migrations.AddRetainedSourceSyncLockVersion do
  use Ecto.Migration

  def change do
    alter table(:brain_retained_sources) do
      add :lock_version, :integer, null: false, default: 1
    end
  end
end
