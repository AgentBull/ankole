defmodule Ankole.Ecto.PluginActivationAllowlistMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.MigratePluginActivationToEnabledIds
  @table "plugin_activation_allowlist_migration_fixture"

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260718153127_migrate_plugin_activation_to_enabled_ids.exs",
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

  test "seeds the fixed shipped-plugin baseline when no blacklist row exists" do
    run_up()

    assert [["global", "plugins.enabled_ids", envelope]] = configuration_rows()

    assert envelope == %{
             "type" => "plaintext",
             "value" => @migration.baseline_enabled_ids()
           }
  end

  test "subtracts the legacy global blacklist and removes ignored scoped rows" do
    insert_configuration("global", "plugins.disabled_ids", [
      "dingtalk-adapter",
      "slack-adapter"
    ])

    insert_configuration("agent:ignored", "plugins.disabled_ids", ["lark-adapter"])

    run_up()

    assert [["global", "plugins.enabled_ids", envelope]] = configuration_rows()

    assert envelope["value"] == [
             "china-market-ai-providers",
             "google-workspace-adapter",
             "lark-adapter",
             "microsoft365-adapter"
           ]
  end

  test "rejects an invalid legacy global value" do
    insert_envelope("global", "plugins.disabled_ids", %{
      "type" => "plaintext",
      "value" => ["lark-adapter", "lark-adapter"]
    })

    assert_raise Postgrex.Error, ~r/invalid plugins.disabled_ids value/, fn -> run_up() end
  end

  test "rejects an existing target key instead of guessing precedence" do
    insert_configuration("global", "plugins.enabled_ids", ["lark-adapter"])

    assert_raise Postgrex.Error, ~r/existing plugins.enabled_ids row/, fn -> run_up() end
  end

  defp run_up do
    Repo.query!(@migration.up_sql(@table))
  end

  defp insert_configuration(scope, key, value) do
    insert_envelope(scope, key, %{"type" => "plaintext", "value" => value})
  end

  defp insert_envelope(scope, key, envelope) do
    Repo.query!(
      """
      INSERT INTO #{@table} (scope, key, value, inserted_at, updated_at)
      VALUES ($1, $2, $3, timezone('UTC', now()), timezone('UTC', now()))
      """,
      [scope, key, envelope]
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
