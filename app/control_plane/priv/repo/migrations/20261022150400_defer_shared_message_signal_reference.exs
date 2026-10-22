defmodule Ankole.Repo.Migrations.DeferSharedMessageSignalReference do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE conversation_messages
      ALTER CONSTRAINT conversation_messages_signal_id_fkey
      DEFERRABLE INITIALLY DEFERRED
    """)
  end

  def down do
    execute("""
    ALTER TABLE conversation_messages
      ALTER CONSTRAINT conversation_messages_signal_id_fkey
      NOT DEFERRABLE INITIALLY IMMEDIATE
    """)
  end
end
