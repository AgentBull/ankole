defmodule Ankole.Repo.Migrations.RetireUltraReasoningEffort do
  use Ecto.Migration

  # No upstream accepts the `ultra` reasoning effort, so the public level set
  # ends at `max`. A stored model profile that still chose `ultra` keeps the
  # operator's intent of the deepest reasoning by moving to `max`. Model profiles
  # nest the option at different depths in each table, and PostgreSQL prints
  # jsonb in one canonical form, so a text replacement reaches every depth.
  @columns [
    {"app_configurations", "value"},
    {"site_app_configurations", "value"},
    {"agents", "options"},
    {"oidc_clients", "model_aliases"}
  ]

  def up do
    for {table, column} <- @columns do
      execute("""
      UPDATE #{table}
      SET #{column} = replace(#{column}::text, '"reasoningEffort": "ultra"', '"reasoningEffort": "max"')::jsonb
      WHERE #{column}::text LIKE '%"reasoningEffort": "ultra"%'
      """)
    end
  end

  # `max` was already a valid choice, so a migrated row cannot be told apart
  # from one that chose `max` itself.
  def down, do: :ok
end
