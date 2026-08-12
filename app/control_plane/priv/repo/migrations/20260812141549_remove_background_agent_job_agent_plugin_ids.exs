defmodule Ankole.Repo.Migrations.RemoveBackgroundAgentJobAgentPluginIds do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE background_agent_jobs DROP COLUMN IF EXISTS agent_plugin_ids")
  end

  # Current code does not read this old column, and its values cannot be restored.
  def down do
    :ok
  end
end
