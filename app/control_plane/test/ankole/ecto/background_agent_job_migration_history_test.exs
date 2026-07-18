defmodule Ankole.Ecto.BackgroundAgentJobMigrationHistoryTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.GuardLegacyBackgroundAgentJobHistory
  @turn_migration Ankole.Repo.Migrations.ReplaceSubagentEventsWithTurns
  @versions_table "background_agent_job_history_versions"
  @pre_rename_archive "background_agent_job_history_pre_rename_archive"
  @live_jobs_table "background_agent_job_history_live_jobs"
  @turns_table "background_agent_job_history_turns"

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260715150611_guard_legacy_background_agent_job_history.exs",
        __DIR__
      )
    )
  end

  unless Code.ensure_loaded?(@turn_migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260715150610_replace_subagent_events_with_turns.exs",
        __DIR__
      )
    )
  end

  test "live V1 Job guard fails before any Turn schema or migration version can change" do
    create_versions!([20_260_715_091_844])

    Repo.query!("""
    CREATE TEMPORARY TABLE #{@live_jobs_table} (
      status text NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!("INSERT INTO #{@live_jobs_table} (status) VALUES ('running')")

    error = postgres_error(@turn_migration.live_job_guard_sql(@live_jobs_table))

    assert error.postgres.code == :check_violation
    assert error.postgres.message =~ "zero non-terminal V1 jobs"
    assert [[20_260_715_091_844]] = Repo.query!("SELECT version FROM #{@versions_table}").rows
    assert [[nil]] = Repo.query!("SELECT to_regclass('#{@turns_table}')").rows
  end

  test "fresh upgrade accepts the archive created by the preserving Turn migration" do
    create_versions!([20_260_715_150_610])
    Repo.query!("CREATE TEMPORARY TABLE #{@pre_rename_archive} (id uuid) ON COMMIT DROP")

    assert %Postgrex.Result{} =
             Repo.query!(
               @migration.guard_sql(
                 @versions_table,
                 @pre_rename_archive
               )
             )
  end

  test "an old applied Turn migration with deleted events fails closed" do
    create_versions!([20_260_715_150_610])

    error = history_guard_error()

    assert error.postgres.code == :check_violation
    assert error.postgres.message =~ "event history is missing"
    assert error.postgres.message =~ "Restore"
  end

  test "an old applied destructive V2 migration fails even if an archive is later fabricated" do
    create_versions!([
      20_260_715_150_610,
      20_260_716_120_707,
      20_260_716_124_417
    ])

    Repo.query!("CREATE TEMPORARY TABLE #{@pre_rename_archive} (id uuid) ON COMMIT DROP")

    error = history_guard_error()

    assert error.postgres.code == :check_violation
    assert error.postgres.message =~ "destructive migration 20260716124417"
    assert error.postgres.message =~ "Restore"
  end

  defp create_versions!(versions) do
    Repo.query!("""
    CREATE TEMPORARY TABLE #{@versions_table} (
      version bigint PRIMARY KEY
    ) ON COMMIT DROP
    """)

    Enum.each(versions, fn version ->
      Repo.query!("INSERT INTO #{@versions_table} (version) VALUES ($1)", [version])
    end)
  end

  defp history_guard_error do
    postgres_error(
      @migration.guard_sql(
        @versions_table,
        @pre_rename_archive
      )
    )
  end

  defp postgres_error(sql) do
    assert_raise Postgrex.Error, fn ->
      Repo.transact(
        fn ->
          Repo.query!(sql)
        end,
        mode: :savepoint
      )
    end
  end
end
