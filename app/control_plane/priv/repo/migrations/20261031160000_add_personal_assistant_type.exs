defmodule Ankole.Repo.Migrations.AddPersonalAssistantType do
  use Ecto.Migration

  def up do
    execute("ALTER TYPE public.agent_type ADD VALUE 'personal_assistant'")
  end

  def down do
    raise "Personal assistants must be removed before restoring the previous schema"
  end
end
