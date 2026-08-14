defmodule Ankole.Repo.Migrations.DropGlobalCompactionPreferUpstream do
  use Ecto.Migration

  # Whether a Provider's native compact operation runs before Ankole's local
  # summary now belongs to each Agent, next to its other provider-hosted
  # capability switches. The global key is no longer part of the compaction
  # settings schema, and a stored row that still carries it fails validation on
  # read. An instance that had turned the global switch on re-enables the
  # capability per Agent.
  def up do
    execute("""
    UPDATE app_configurations
    SET value = jsonb_set(value, '{value}', (value -> 'value') - 'prefer_upstream')
    WHERE key = 'ai_gateway.compaction'
      AND jsonb_typeof(value -> 'value') = 'object'
      AND value -> 'value' ? 'prefer_upstream'
    """)
  end

  # The key no longer exists in the schema, so restoring it would write a value
  # the settings write path rejects.
  def down, do: :ok
end
