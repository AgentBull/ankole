defmodule Ankole.Ecto.BackgroundAgentJobMigrationHistoryTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.ReplaceSubagentEventsWithTurns
  @legacy_job_id "00000000-0000-0000-0000-000000000001"
  @legacy_dispatch_event_id "00000000-0000-0000-0000-000000000002"
  @legacy_completion_event_id "00000000-0000-0000-0000-000000000003"
  @unrelated_event_id "00000000-0000-0000-0000-000000000004"

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260715150610_replace_subagent_events_with_turns.exs",
        __DIR__
      )
    )
  end

  test "v26.07.7 runtime state is discarded without touching unrelated actor state" do
    create_v26_07_7_runtime_fixture!()

    Enum.each(@migration.legacy_runtime_purge_sqls(), &Repo.query!/1)

    assert [[0]] = Repo.query!("SELECT count(*) FROM subagent_delegations").rows
    assert [[0]] = Repo.query!("SELECT count(*) FROM subagent_delegation_events").rows

    for {table, column} <- session_tables() do
      assert [["main:kept"]] =
               Repo.query!("SELECT #{column} FROM #{table} ORDER BY #{column}").rows
    end

    assert [["main.event", "main:event", "main:kept"]] =
             Repo.query!("""
             SELECT type, source_event_id, session_id
             FROM actor_events
             ORDER BY type
             """).rows

    assert [["main:kept", @unrelated_event_id, @unrelated_event_id]] =
             Repo.query!("""
             SELECT session_id, actor_event_id::text, actor_event_id_fence::text
             FROM actor_event_deliveries
             """).rows
  end

  test "cutover refuses a lossy downgrade" do
    assert_raise RuntimeError, ~r/intentionally discarded/, fn -> @migration.down() end
  end

  defp create_v26_07_7_runtime_fixture! do
    schema = "background_agent_job_cutover_#{System.unique_integer([:positive])}"

    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")

    Repo.query!("""
    CREATE TABLE actor_events (
      id uuid PRIMARY KEY,
      type text NOT NULL,
      source_event_id text NOT NULL,
      session_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE actor_event_deliveries (
      session_id text NOT NULL,
      actor_event_id uuid NOT NULL,
      actor_event_id_fence uuid NOT NULL
    )
    """)

    for {table, column} <- session_tables() do
      Repo.query!("CREATE TABLE #{table} (#{column} text NOT NULL)")
    end

    Repo.query!("CREATE TABLE subagent_delegations (id uuid PRIMARY KEY)")

    Repo.query!("""
    CREATE TABLE subagent_delegation_events (
      delegation_id uuid NOT NULL REFERENCES subagent_delegations(id) ON DELETE CASCADE
    )
    """)

    Repo.query!("""
    INSERT INTO actor_events (id, type, source_event_id, session_id)
    VALUES
      ('#{@legacy_dispatch_event_id}', 'subagent.delegation.dispatch',
       'subagent_delegation:#{@legacy_job_id}:dispatch:0', 'subagent:#{@legacy_job_id}'),
      ('#{@legacy_completion_event_id}', 'subagent.delegation.completed',
       'subagent_delegation:#{@legacy_job_id}:succeeded', 'main:owner'),
      ('#{@unrelated_event_id}', 'main.event', 'main:event', 'main:kept')
    """)

    Repo.query!("""
    INSERT INTO actor_event_deliveries (session_id, actor_event_id, actor_event_id_fence)
    VALUES
      ('subagent:#{@legacy_job_id}', '#{@legacy_dispatch_event_id}', '#{@legacy_dispatch_event_id}'),
      ('main:owner', '#{@legacy_completion_event_id}', '#{@legacy_completion_event_id}'),
      ('main:kept', '#{@unrelated_event_id}', '#{@unrelated_event_id}')
    """)

    for {table, column} <- session_tables() do
      Repo.query!("""
      INSERT INTO #{table} (#{column})
      VALUES ('subagent:#{@legacy_job_id}'), ('main:kept')
      """)
    end

    Repo.query!("INSERT INTO subagent_delegations (id) VALUES ('#{@legacy_job_id}')")

    Repo.query!(
      "INSERT INTO subagent_delegation_events (delegation_id) VALUES ('#{@legacy_job_id}')"
    )
  end

  defp session_tables do
    [
      {"actor_session_activations", "session_id"},
      {"actor_session_worker_assignments", "session_id"},
      {"actor_scheduled_events", "session_id"},
      {"actor_cron_schedules", "session_id"},
      {"signal_gateway_inbound_batches", "session_id"},
      {"ai_gateway_conversations", "conversation_key"}
    ]
  end
end
