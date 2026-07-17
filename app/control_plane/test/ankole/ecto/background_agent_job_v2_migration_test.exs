defmodule Ankole.Ecto.BackgroundAgentJobV2MigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library
  alias Ankole.PrincipalsFixtures
  alias Ankole.Repo

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
end
