defmodule Ankole.Repo.Migrations.RequestInitialWorkerStart do
  use Ecto.Migration

  def change do
    alter table(:agent_workers) do
      add :initial_start_pending, :boolean,
        null: false,
        default: false,
        comment: "Agent creation requests startup until the Worker first connects."
    end
  end
end
