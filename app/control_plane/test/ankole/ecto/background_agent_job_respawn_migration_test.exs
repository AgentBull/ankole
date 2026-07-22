defmodule Ankole.Ecto.BackgroundAgentJobRespawnMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.AddBackgroundAgentJobRespawn

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260721191603_add_background_agent_job_respawn.exs",
        __DIR__
      )
    )
  end

  test "current schema stores one successor and one stable workspace owner" do
    assert [
             ["background_agent_job_turns", "job_id", "int8"],
             ["background_agent_jobs", "continued_from_job_id", "int8"],
             ["background_agent_jobs", "id", "int8"],
             ["background_agent_jobs", "workspace_owner_job_id", "int8"]
           ] =
             Repo.query!("""
             SELECT table_name, column_name, udt_name
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND (
                 (table_name = 'background_agent_jobs'
                   AND column_name IN ('id', 'continued_from_job_id', 'workspace_owner_job_id'))
                 OR (table_name = 'background_agent_job_turns' AND column_name = 'job_id')
               )
             ORDER BY table_name, column_name
             """).rows

    assert [["continued_from_job_id", "YES"], ["workspace_owner_job_id", "NO"]] =
             Repo.query!("""
             SELECT column_name, is_nullable
             FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'background_agent_jobs'
               AND column_name IN ('continued_from_job_id', 'workspace_owner_job_id')
             ORDER BY column_name
             """).rows

    assert [
             ["background_agent_jobs_continued_from_job_id_fkey"],
             ["background_agent_jobs_continued_from_not_self"],
             ["background_agent_jobs_workspace_owner_job_id_fkey"]
           ] =
             Repo.query!("""
             SELECT conname
             FROM pg_constraint
             WHERE conname IN (
               'background_agent_jobs_continued_from_job_id_fkey',
               'background_agent_jobs_continued_from_not_self',
               'background_agent_jobs_workspace_owner_job_id_fkey'
             )
             ORDER BY conname
             """).rows

    assert [["background_agent_jobs_continued_from_job_index"]] =
             Repo.query!("""
             SELECT indexname
             FROM pg_indexes
             WHERE schemaname = current_schema()
               AND tablename = 'background_agent_jobs'
               AND indexname = 'background_agent_jobs_continued_from_job_index'
             """).rows
  end

  test "respawn history cannot be removed by downgrade" do
    assert_raise RuntimeError, ~r/continuation history cannot be removed/, fn ->
      @migration.down()
    end
  end
end
