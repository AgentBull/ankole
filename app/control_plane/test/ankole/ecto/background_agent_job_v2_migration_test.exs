defmodule Ankole.Ecto.BackgroundAgentJobV2MigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library
  alias Ankole.PrincipalsFixtures
  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.AddAgentPluginsAndBackgroundAgentJobV2
  @config_fixture_table "background_agent_job_v2_config_fixture"

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260716124417_add_agent_plugins_and_background_agent_job_v2.exs",
        __DIR__
      )
    )
  end

  test "per-Agent Plugin state is sparse and stores only explicit enablement" do
    %{principal: agent} = PrincipalsFixtures.agent_fixture()

    assert {:ok, %{skills: skill_count}} = Library.sync_agent_skills(agent.uid)
    assert skill_count > 0

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

  test "rendered-fetch configuration rename preserves scope, value, and unrelated settings" do
    Repo.query!("""
    CREATE TEMPORARY TABLE #{@config_fixture_table} (
      scope text NOT NULL,
      key text NOT NULL,
      value jsonb NOT NULL,
      inserted_at timestamp NOT NULL,
      updated_at timestamp NOT NULL,
      UNIQUE (scope, key)
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    INSERT INTO #{@config_fixture_table} (scope, key, value, inserted_at, updated_at)
    VALUES
      (
        'global',
        'worker.local_browser_idle_ttl_ms',
        '{"type":"plaintext","value":60000}'::jsonb,
        timezone('UTC', now()),
        timezone('UTC', now())
      ),
      (
        'agent:kept',
        'worker.local_browser_idle_ttl_ms',
        '{"type":"plaintext","value":120000}'::jsonb,
        timezone('UTC', now()),
        timezone('UTC', now())
      ),
      (
        'global',
        'unrelated.encrypted',
        '{"type":"encrypted","value":{"ciphertext":"kept"}}'::jsonb,
        timezone('UTC', now()),
        timezone('UTC', now())
      )
    """)

    Repo.query!(@migration.rendered_fetch_config_key_migration_sql(@config_fixture_table))

    assert [
             [
               "agent:kept",
               "worker.rendered_fetch_idle_ttl_ms",
               %{"type" => "plaintext", "value" => 120_000}
             ],
             [
               "global",
               "unrelated.encrypted",
               %{"type" => "encrypted", "value" => %{"ciphertext" => "kept"}}
             ],
             [
               "global",
               "worker.rendered_fetch_idle_ttl_ms",
               %{"type" => "plaintext", "value" => 60_000}
             ]
           ] =
             Repo.query!("""
             SELECT scope, key, value
             FROM #{@config_fixture_table}
             ORDER BY scope, key
             """).rows
  end
end
