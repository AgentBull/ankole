defmodule Ankole.Repo.Migrations.AddWorkerIncarnationID do
  use Ecto.Migration

  def up do
    alter table(:agent_computer_workers) do
      add :incarnation_id, :text
    end

    execute("""
    UPDATE agent_computer_workers
    SET incarnation_id = 'pre-incarnation:' || worker_id
    WHERE incarnation_id IS NULL
    """)

    alter table(:agent_computer_workers) do
      modify :incarnation_id, :text, null: false
    end

    execute(
      "COMMENT ON COLUMN agent_computer_workers.incarnation_id IS 'One concrete process lifetime behind the stable worker id.'"
    )
  end

  def down do
    alter table(:agent_computer_workers) do
      remove :incarnation_id
    end
  end
end
