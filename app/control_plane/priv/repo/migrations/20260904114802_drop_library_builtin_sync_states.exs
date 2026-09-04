defmodule Ankole.Repo.Migrations.DropLibraryBuiltinSyncStates do
  use Ecto.Migration

  def up do
    drop table(:library_builtin_sync_states)
  end

  def down do
    raise Ecto.MigrationError,
      message: "the obsolete builtin Skill sync cursor cannot be restored"
  end
end
