defmodule Ankole.Ecto.BackgroundAgentJobNamingMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.RenameSubagentDelegationsToBackgroundAgentJobs
  @table "background_agent_job_config_migration_fixture"
  @old_key "agent_computer.subagent.max_delegation_turns_per_worker"
  @new_key "agent_computer.background_agent_job.max_turns_per_worker"

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260716120707_rename_subagent_delegations_to_background_agent_jobs.exs",
        __DIR__
      )
    )
  end

  setup do
    Repo.query!("""
    CREATE TEMPORARY TABLE #{@table} (
      scope text NOT NULL,
      key text NOT NULL,
      value jsonb NOT NULL,
      inserted_at timestamp NOT NULL,
      updated_at timestamp NOT NULL,
      UNIQUE (scope, key)
    ) ON COMMIT DROP
    """)

    :ok
  end

  test "renames the BackgroundAgentJob configuration without changing scope or value" do
    insert_configuration("global", @old_key, 7)
    insert_configuration("agent:kept", @old_key, 3)
    insert_configuration("global", "unrelated.encrypted", %{"ciphertext" => "kept"})

    Repo.query!(@migration.config_key_migration_sql(@table))

    assert [
             ["agent:kept", @new_key, %{"type" => "plaintext", "value" => 3}],
             ["global", @new_key, %{"type" => "plaintext", "value" => 7}],
             [
               "global",
               "unrelated.encrypted",
               %{"type" => "encrypted", "value" => %{"ciphertext" => "kept"}}
             ]
           ] = configuration_rows()
  end

  test "rejects conflicting old and new keys in the same scope" do
    insert_configuration("global", @old_key, 7)
    insert_configuration("global", @new_key, 9)

    assert_raise Postgrex.Error, ~r/Both old and new BackgroundAgentJob/, fn ->
      Repo.query!(@migration.config_key_migration_sql(@table))
    end
  end

  defp insert_configuration(scope, key, value) do
    type = if is_map(value), do: "encrypted", else: "plaintext"

    Repo.query!(
      """
      INSERT INTO #{@table} (scope, key, value, inserted_at, updated_at)
      VALUES ($1, $2, $3, timezone('UTC', now()), timezone('UTC', now()))
      """,
      [scope, key, %{"type" => type, "value" => value}]
    )
  end

  defp configuration_rows do
    Repo.query!("""
    SELECT scope, key, value
    FROM #{@table}
    ORDER BY scope, key
    """).rows
  end
end
