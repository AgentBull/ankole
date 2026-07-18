defmodule Ankole.Ecto.BackgroundAgentJobMigrationHistoryTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.GuardLegacyBackgroundAgentJobHistory
  @turn_migration Ankole.Repo.Migrations.ReplaceSubagentEventsWithTurns
  @versions_table "background_agent_job_history_versions"
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
    create_history_schema!([20_260_715_150_610], :pre_rename)
    Repo.query!("CREATE TABLE subagent_delegation_legacy_events (id uuid)")

    assert %Postgrex.Result{} = Repo.query!(@migration.guard_sql())
  end

  test "an old Turn draft with surviving Job evidence still fails closed" do
    create_history_schema!([20_260_715_150_610], :pre_rename)

    Repo.query!("""
    INSERT INTO subagent_delegations (id)
    VALUES ('00000000-0000-0000-0000-000000000001')
    """)

    error = postgres_error(@migration.guard_sql())

    assert error.postgres.code == :check_violation
    assert error.postgres.message =~ "durable Job or actor-event evidence survives"
    assert error.postgres.message =~ "Restore"
  end

  test "an old destructive V2 draft with surviving actor evidence still fails closed" do
    create_history_schema!(
      [20_260_715_150_610, 20_260_716_120_707, 20_260_716_124_417],
      :post_rename
    )

    Repo.query!("CREATE TABLE background_agent_job_legacy_events (id uuid)")

    Repo.query!("""
    INSERT INTO actor_events (type, source_event_id, session_id)
    VALUES (
      'background_agent_job.dispatch',
      'background_agent_job:00000000-0000-0000-0000-000000000001:dispatch',
      'job:00000000-0000-0000-0000-000000000001'
    )
    """)

    error = postgres_error(@migration.guard_sql())

    assert error.postgres.code == :check_violation
    assert error.postgres.message =~ "durable Job or actor-event evidence survives"
    assert error.postgres.message =~ "Restore"
  end

  test "an old destructive V2 draft with provably empty history gets an empty final archive" do
    create_history_schema!(
      [20_260_715_150_610, 20_260_716_120_707, 20_260_716_124_417],
      :post_rename
    )

    assert %Postgrex.Result{} = Repo.query!(@migration.guard_sql())
    assert %Postgrex.Result{} = Repo.query!(@migration.repair_empty_archive_sql())
    assert %Postgrex.Result{} = Repo.query!(@migration.repair_empty_archive_sql())

    assert [["background_agent_job_legacy_events"]] =
             Repo.query!("SELECT to_regclass('background_agent_job_legacy_events')::text").rows

    assert [[0]] = Repo.query!("SELECT count(*) FROM background_agent_job_legacy_events").rows

    assert [["job_id"]] =
             Repo.query!("""
             SELECT column_name
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'background_agent_job_legacy_events'
               AND column_name = 'job_id'
             """).rows

    assert [
             ["background_agent_job_legacy_events_agent_uid_fkey", "r"],
             ["background_agent_job_legacy_events_job_id_fkey", "r"]
           ] =
             Repo.query!("""
             SELECT conname, confdeltype::text
             FROM pg_constraint
             WHERE conrelid = 'background_agent_job_legacy_events'::regclass
               AND contype = 'f'
             ORDER BY conname
             """).rows

    assert [[comment]] =
             Repo.query!("""
             SELECT obj_description('background_agent_job_legacy_events'::regclass, 'pg_class')
             """).rows

    assert comment =~ "Control-plane-owned immutable archive"
  end

  defp create_history_schema!(versions, stage) do
    schema = "background_agent_job_history_#{System.unique_integer([:positive])}"

    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")
    Repo.query!("CREATE TABLE schema_migrations (version bigint PRIMARY KEY)")
    Repo.query!("CREATE TABLE principals (uid text PRIMARY KEY)")

    case stage do
      :pre_rename -> Repo.query!("CREATE TABLE subagent_delegations (id uuid PRIMARY KEY)")
      :post_rename -> Repo.query!("CREATE TABLE background_agent_jobs (id uuid PRIMARY KEY)")
    end

    Repo.query!("""
    CREATE TABLE actor_events (
      type text,
      source_event_id text,
      session_id text
    )
    """)

    Enum.each(versions, fn version ->
      Repo.query!("INSERT INTO schema_migrations (version) VALUES ($1)", [version])
    end)
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
