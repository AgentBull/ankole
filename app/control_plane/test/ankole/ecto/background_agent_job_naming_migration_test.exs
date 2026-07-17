defmodule Ankole.Ecto.BackgroundAgentJobNamingMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.RenameSubagentDelegationsToBackgroundAgentJobs
  @table "background_agent_job_migration_actor_events"

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260716120707_rename_subagent_delegations_to_background_agent_jobs.exs",
        __DIR__
      )
    )
  end

  test "historical actor event payloads survive the up and down rewrite" do
    historical_payload = %{
      "data" => %{
        "attempts" => 0,
        "delegation_id" => "019f6aa0-3f4d-7573-b4a8-bde808f3011f",
        "parent_session_id" => "signal:lark:chat-1",
        "workdir" => "/workspace/user-files/subagent-runs/019f6aa0"
      },
      "id" => "subagent_delegation:019f6aa0-3f4d-7573-b4a8-bde808f3011f:dispatch:0",
      "source" => "control-plane://subagent/delegation",
      "specversion" => "1.0",
      "subject" => "subagent-delegation:019f6aa0-3f4d-7573-b4a8-bde808f3011f",
      "type" => "subagent.delegation.dispatch"
    }

    Repo.query!("""
    CREATE TEMPORARY TABLE #{@table} (
      type text NOT NULL,
      source_event_id text NOT NULL,
      payload jsonb NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!(
      """
      INSERT INTO #{@table} (type, source_event_id, payload)
      VALUES ($1, $2, $3)
      """,
      [
        historical_payload["type"],
        "subagent_delegation:019f6aa0-3f4d-7573-b4a8-bde808f3011f:dispatch:0",
        historical_payload
      ]
    )

    run_rewrite(:up)

    assert [
             "background_agent_job.dispatch",
             "background_agent_job:019f6aa0-3f4d-7573-b4a8-bde808f3011f:dispatch:0",
             migrated_payload
           ] = event_row()

    assert migrated_payload == %{
             historical_payload
             | "data" => %{
                 "attempts" => 0,
                 "job_id" => "019f6aa0-3f4d-7573-b4a8-bde808f3011f",
                 "owner_session_id" => "signal:lark:chat-1",
                 "workdir" => "/workspace/user-files/subagent-runs/019f6aa0"
               },
               "id" => "background_agent_job:019f6aa0-3f4d-7573-b4a8-bde808f3011f:dispatch:0",
               "source" => "control-plane://background-agent-job",
               "subject" => "background-agent-job:019f6aa0-3f4d-7573-b4a8-bde808f3011f",
               "type" => "background_agent_job.dispatch"
           }

    run_rewrite(:down)

    assert [
             "subagent.delegation.dispatch",
             "subagent_delegation:019f6aa0-3f4d-7573-b4a8-bde808f3011f:dispatch:0",
             ^historical_payload
           ] = event_row()
  end

  defp run_rewrite(direction) do
    direction
    |> @migration.actor_event_rewrite_sqls(@table)
    |> Enum.each(&Repo.query!/1)
  end

  defp event_row do
    Repo.query!("SELECT type, source_event_id, payload FROM #{@table}").rows
    |> List.first()
  end
end
