defmodule Ankole.Repo.Migrations.RemoveActorSessionWorkerAssignmentWorkspaceMount do
  use Ecto.Migration

  def change do
    alter table(:actor_session_worker_assignments) do
      remove(:workspace_mount, :text)
    end
  end
end
