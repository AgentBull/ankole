defmodule Ankole.Repo.Migrations.RenameConversationRuntimeToSessions do
  use Ecto.Migration

  @previous_runtime "Ankole.Conversations"

  def up do
    rename table(:conversation_round_states), to: table(:session_round_states)
    rename table(:conversation_tool_receipts), to: table(:session_tool_receipts)

    execute("""
    DO $$
    DECLARE stored_constraint record;
    BEGIN
      FOR stored_constraint IN
        SELECT conrelid::regclass AS table_name, conname
        FROM pg_constraint
        WHERE conrelid IN ('session_round_states'::regclass, 'session_tool_receipts'::regclass)
          AND left(conname, 13) = 'conversation_'
      LOOP
        EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I',
          stored_constraint.table_name, stored_constraint.conname,
          'session_' || substring(stored_constraint.conname FROM 14));
      END LOOP;
    END $$
    """)

    for {previous, current} <- [
          {:conversation_round_states_tenant_id_index, :session_round_states_tenant_id_index},
          {:conversation_tool_receipts_agent_uid_session_id_index,
           :session_tool_receipts_agent_uid_session_id_index},
          {:conversation_tool_receipts_tenant_id_index, :session_tool_receipts_tenant_id_index}
        ] do
      execute("ALTER INDEX #{previous} RENAME TO #{current}")
    end

    execute("""
    UPDATE oban_jobs
    SET worker = 'Ankole.Sessions' || substring(worker FROM #{String.length(@previous_runtime) + 1})
    WHERE left(worker, #{String.length(@previous_runtime) + 1}) = '#{@previous_runtime}.'
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "restore the pre-upgrade database backup and its matching runtime code"
  end
end
