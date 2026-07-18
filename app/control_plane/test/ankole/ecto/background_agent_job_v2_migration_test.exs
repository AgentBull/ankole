defmodule Ankole.Ecto.BackgroundAgentJobV2MigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library
  alias Ankole.PrincipalsFixtures
  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.AddAgentPluginsAndBackgroundAgentJobV2
  @legacy_fixture_table "background_agent_job_v2_legacy_fixture"

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260716124417_add_agent_plugins_and_background_agent_job_v2.exs",
        __DIR__
      )
    )
  end

  test "V2 schema keeps only Agent Plugin selections and generic Job execution fields" do
    job_columns =
      Repo.query!("""
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'background_agent_jobs'
      ORDER BY column_name
      """).rows
      |> List.flatten()
      |> MapSet.new()

    for column <- ~w(agent_plugin_ids skill_names workspace_mounts model reasoning_effort) do
      assert MapSet.member?(job_columns, column)
    end

    refute MapSet.member?(job_columns, "agent_plugins")

    [[source_kind_constraint]] =
      Repo.query!("""
      SELECT pg_get_constraintdef(oid)
      FROM pg_constraint
      WHERE conname = 'agent_skills_source_kind_check'
      """).rows

    assert source_kind_constraint =~ "builtin"
    assert source_kind_constraint =~ "installed"
    refute source_kind_constraint =~ "agent_plugin"

    assert [] =
             Repo.query!("""
             SELECT 1
             FROM pg_constraint
             WHERE conname = 'agent_skills_agent_plugin_ownership'
             """).rows

    plugin_columns =
      Repo.query!("""
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'agent_plugin_overrides'
      ORDER BY column_name
      """).rows
      |> List.flatten()

    assert plugin_columns ==
             ~w(agent_plugin_id agent_uid enabled id inserted_at updated_at)
  end

  test "per-Agent Plugin state is sparse and stores only explicit enablement" do
    %{principal: agent} = PrincipalsFixtures.agent_fixture()

    assert {:ok, %{skills: 12}} = Library.sync_agent_skills(agent.uid)

    assert [[0]] = Repo.query!("SELECT count(*) FROM agent_plugin_overrides").rows

    assert {:ok, %{agent_plugin_id: "deep-research", enabled: false}} =
             AgentPlugins.set_agent_override(agent.uid, "deep-research", false)

    assert [["deep-research", false]] =
             Repo.query!(
               """
               SELECT agent_plugin_id, enabled
               FROM agent_plugin_overrides
               WHERE agent_uid = $1
               """,
               [agent.uid]
             ).rows

    assert {:ok, nil} = AgentPlugins.set_agent_override(agent.uid, "deep-research", nil)
    assert [[0]] = Repo.query!("SELECT count(*) FROM agent_plugin_overrides").rows
  end

  test "pre-V2 Job fields remain as informational metadata while V2 resume stays disabled" do
    Repo.query!("""
    CREATE TEMPORARY TABLE #{@legacy_fixture_table} (
      id uuid PRIMARY KEY,
      status text NOT NULL,
      metadata jsonb NOT NULL,
      runtime text NOT NULL,
      runtime_thread_id text,
      workdir text,
      mode text,
      source_job_id uuid,
      actual_outcome boolean,
      workspace_retention_days integer,
      workspace_cleaned_at timestamp,
      agent_plugin_ids text[] NOT NULL DEFAULT '{}',
      skill_names text[] NOT NULL DEFAULT '{}',
      workspace_mounts jsonb
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    INSERT INTO #{@legacy_fixture_table} (
      id,
      status,
      metadata,
      runtime,
      runtime_thread_id,
      workdir,
      mode,
      source_job_id,
      actual_outcome,
      workspace_retention_days,
      workspace_cleaned_at
    )
    VALUES
      (
        '019f7374-93cb-7d91-9346-2a15e2e4c001',
        'succeeded',
        '{"existing":"kept"}'::jsonb,
        'task_worker',
        'thread-task-worker',
        '/tmp/pre-v2-task-worker',
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
      ),
      (
        '019f7374-93cb-7d91-9346-2a15e2e4c002',
        'failed',
        '{}'::jsonb,
        'deep_research',
        'thread-deep-research',
        '/tmp/pre-v2-deep-research',
        'retrospect',
        '019f7374-93cb-7d91-9346-2a15e2e4c001',
        true,
        30,
        '2026-07-15 12:34:56'
      )
    """)

    Repo.query!(@migration.legacy_job_v2_guard_sql(@legacy_fixture_table))
    Repo.query!(@migration.legacy_job_v2_backfill_sql(@legacy_fixture_table))

    assert [task_worker, deep_research] =
             Repo.query!("""
             SELECT
               id::text,
               runtime_thread_id,
               agent_plugin_ids,
               skill_names,
               workspace_mounts,
               metadata
             FROM #{@legacy_fixture_table}
             ORDER BY id
             """).rows

    assert [task_worker_id, nil, [], [], [task_worker_mount], task_worker_metadata] = task_worker

    assert task_worker_mount == %{
             "access" => "read_write",
             "id" => "workspace",
             "source" => "/workspace/user-files/background-agent-jobs/#{task_worker_id}/workspace"
           }

    assert task_worker_metadata["existing"] == "kept"

    assert task_worker_metadata[@migration.legacy_snapshot_key()] == %{
             "runtime" => "task_worker",
             "runtime_thread_id" => "thread-task-worker",
             "v2_resume_disabled_reason" => "pre_v2_runtime_state_is_not_resumable",
             "v2_resume_supported" => false,
             "v2_workspace_mount_materialized" => false,
             "workdir" => "/tmp/pre-v2-task-worker"
           }

    refute Map.has_key?(task_worker_metadata, "managed_background_agent_job_root")
    refute Map.has_key?(task_worker_metadata, "managed_workspace_mount_ids")

    assert [deep_research_id, nil, ["deep-research"], [], [deep_research_mount], metadata] =
             deep_research

    assert deep_research_mount["source"] ==
             "/workspace/user-files/background-agent-jobs/#{deep_research_id}/workspace"

    assert metadata[@migration.legacy_snapshot_key()]["source_job_id"] == task_worker_id
    assert metadata[@migration.legacy_snapshot_key()]["workspace_retention_days"] == 30
  end

  test "V2 migration refuses an untrusted metadata-based downgrade" do
    error = assert_raise RuntimeError, fn -> @migration.down() end

    assert error.message =~ "cannot be downgraded"
    assert error.message =~ "untrusted informational metadata"
  end

  test "raw pre-Turn events remain in the owned legacy archive" do
    assert [[comment]] =
             Repo.query!("""
             SELECT obj_description('background_agent_job_legacy_events'::regclass, 'pg_class')
             """).rows

    assert comment =~ "Control-plane-owned immutable archive"
    assert comment =~ "explicit export or retention migration"

    assert [["job_id"]] =
             Repo.query!("""
             SELECT column_name
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'background_agent_job_legacy_events'
               AND column_name = 'job_id'
             """).rows

    expected_names =
      MapSet.new(~w(
        background_agent_job_legacy_events_agent_inserted_index
        background_agent_job_legacy_events_agent_uid_fkey
        background_agent_job_legacy_events_agent_uid_not_null
        background_agent_job_legacy_events_direction_check
        background_agent_job_legacy_events_direction_not_null
        background_agent_job_legacy_events_event_type_not_null
        background_agent_job_legacy_events_id_not_null
        background_agent_job_legacy_events_inserted_at_not_null
        background_agent_job_legacy_events_job_id_fkey
        background_agent_job_legacy_events_job_id_not_null
        background_agent_job_legacy_events_job_seq_index
        background_agent_job_legacy_events_occurred_at_not_null
        background_agent_job_legacy_events_payload_not_null
        background_agent_job_legacy_events_payload_object
        background_agent_job_legacy_events_pkey
        background_agent_job_legacy_events_redaction_not_null
        background_agent_job_legacy_events_redaction_object
        background_agent_job_legacy_events_seq_not_null
        background_agent_job_legacy_events_updated_at_not_null
      ))

    actual_names =
      Repo.query!("""
      SELECT conname
      FROM pg_constraint
      WHERE conrelid = 'background_agent_job_legacy_events'::regclass
      UNION ALL
      SELECT indexrelid::regclass::text
      FROM pg_index
      WHERE indrelid = 'background_agent_job_legacy_events'::regclass
        AND NOT indisprimary
      """).rows
      |> List.flatten()
      |> MapSet.new()

    assert actual_names == expected_names
    assert Enum.all?(actual_names, &(byte_size(&1) <= 63))

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
  end
end
