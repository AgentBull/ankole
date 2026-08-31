defmodule Ankole.Repo.Migrations.MoveBrainModelsToMaintainerAgent do
  use Ecto.Migration

  # Brain now reads these capabilities from the selected maintainer Agent.
  # Keeping the old rows would preserve a second, unreachable model owner.
  def up do
    execute("""
    DELETE FROM app_configurations
    WHERE key IN (
      'brain.web_fetch_model',
      'brain.extraction_model',
      'brain.dreaming_model'
    )
    """)
  end

  def down, do: :ok
end
