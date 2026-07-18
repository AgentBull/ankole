defmodule Ankole.Repo.Migrations.GuardLegacyBackgroundAgentJobHistory do
  use Ecto.Migration

  @naming_version 20_260_716_120_707
  @destructive_v2_version 20_260_716_124_417

  def up do
    execute(guard_sql())

    Enum.each(restrict_archive_fk_sqls(), fn statement ->
      execute(statement)
    end)
  end

  def down, do: :ok

  @doc false
  def guard_sql(
        schema_migrations_table \\ "schema_migrations",
        pre_rename_archive \\ "subagent_delegation_legacy_events"
      ) do
    schema_migrations_table = validate_table!(schema_migrations_table)
    pre_rename_archive = validate_table!(pre_rename_archive)

    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{schema_migrations_table}
        WHERE version = #{@destructive_v2_version}
      ) THEN
        RAISE EXCEPTION
          'Legacy BackgroundAgentJob history cannot be proven because destructive migration 20260716124417 was recorded before the preservation guard. Restore the database from a backup at or before 20260714000003 and rerun migrations; automatic repair would fabricate deleted Jobs or events.'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM #{schema_migrations_table}
        WHERE version = #{@naming_version}
      ) THEN
        RAISE EXCEPTION
          'Legacy BackgroundAgentJob history cannot be proven because naming migration 20260716120707 was recorded before the preservation guard. Restore the database from a backup at or before 20260714000003 and rerun migrations; automatic repair would fabricate deleted event history.'
          USING ERRCODE = 'check_violation';
      END IF;

      IF to_regclass('#{pre_rename_archive}') IS NULL THEN
        RAISE EXCEPTION
          'Legacy BackgroundAgentJob event history is missing after migration 20260715150610. Restore the pre-migration event table from backup as subagent_delegation_legacy_events before continuing; automatic repair is intentionally disabled.'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """
  end

  defp restrict_archive_fk_sqls do
    [
      "ALTER TABLE subagent_delegation_legacy_events DROP CONSTRAINT subagent_delegation_events_delegation_id_fkey",
      """
      ALTER TABLE subagent_delegation_legacy_events
      ADD CONSTRAINT subagent_delegation_events_delegation_id_fkey
      FOREIGN KEY (delegation_id) REFERENCES subagent_delegations(id) ON DELETE RESTRICT
      """,
      "ALTER TABLE subagent_delegation_legacy_events DROP CONSTRAINT subagent_delegation_events_agent_uid_fkey",
      """
      ALTER TABLE subagent_delegation_legacy_events
      ADD CONSTRAINT subagent_delegation_events_agent_uid_fkey
      FOREIGN KEY (agent_uid) REFERENCES principals(uid) ON DELETE RESTRICT
      """
    ]
  end

  defp validate_table!(table) do
    if is_binary(table) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, table) do
      table
    else
      raise ArgumentError, "invalid migration table name"
    end
  end
end
