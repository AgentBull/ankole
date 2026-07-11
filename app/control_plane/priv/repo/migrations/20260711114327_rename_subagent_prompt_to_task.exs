defmodule Ankole.Repo.Migrations.RenameSubagentPromptToTask do
  use Ecto.Migration

  def up do
    rename table(:subagent_delegations), :prompt, to: :task

    alter table(:subagent_delegations) do
      modify :title, :text, null: false
      modify :task, :text, null: false
      add :background, :text
      add :notes, :text
    end
  end

  def down do
    alter table(:subagent_delegations) do
      remove :notes
      remove :background
      modify :task, :text, null: true
      modify :title, :text, null: true
    end

    rename table(:subagent_delegations), :task, to: :prompt
  end
end
