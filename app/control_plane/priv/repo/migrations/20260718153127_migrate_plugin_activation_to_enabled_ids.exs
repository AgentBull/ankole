defmodule Ankole.Repo.Migrations.MigratePluginActivationToEnabledIds do
  use Ecto.Migration

  @baseline_enabled_ids [
    "china-market-ai-providers",
    "dingtalk-adapter",
    "google-workspace-adapter",
    "lark-adapter",
    "microsoft365-adapter",
    "slack-adapter"
  ]

  def up do
    execute(up_sql())
  end

  def down do
    raise "Control Plane Plugin enable-list migration cannot be downgraded: a blacklist cannot preserve fail-closed behavior for future plugin ids"
  end

  @doc false
  def baseline_enabled_ids, do: @baseline_enabled_ids

  @doc false
  def up_sql(table \\ "app_configurations") do
    table = validate_table!(table)

    baseline_values =
      @baseline_enabled_ids
      |> Enum.with_index(1)
      |> Enum.map_join(",\n", fn {id, ordinal} -> "('#{id}', #{ordinal})" end)

    """
    DO $$
    DECLARE
      legacy_value jsonb;
      migrated_enabled_ids jsonb;
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{table}
        WHERE key = 'plugins.enabled_ids'
      ) THEN
        RAISE EXCEPTION
          'Control Plane Plugin activation migration found an existing plugins.enabled_ids row'
          USING ERRCODE = 'unique_violation';
      END IF;

      SELECT value
      INTO legacy_value
      FROM #{table}
      WHERE scope = 'global' AND key = 'plugins.disabled_ids';

      IF FOUND AND (
        legacy_value->>'type' IS DISTINCT FROM 'plaintext'
        OR jsonb_typeof(legacy_value->'value') IS DISTINCT FROM 'array'
        OR EXISTS (
          SELECT 1
          FROM jsonb_array_elements(legacy_value->'value') AS item
          WHERE jsonb_typeof(item) <> 'string'
             OR item #>> '{}' !~ '^[a-z][a-z0-9_-]*$'
        )
        OR (
          SELECT count(*)
          FROM jsonb_array_elements(legacy_value->'value')
        ) <> (
          SELECT count(DISTINCT item #>> '{}')
          FROM jsonb_array_elements(legacy_value->'value') AS item
        )
      ) THEN
        RAISE EXCEPTION
          'Control Plane Plugin activation migration found an invalid plugins.disabled_ids value'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT COALESCE(jsonb_agg(plugin_id ORDER BY ordinal), '[]'::jsonb)
      INTO migrated_enabled_ids
      FROM (VALUES
        #{baseline_values}
      ) AS baseline(plugin_id, ordinal)
      WHERE legacy_value IS NULL
         OR NOT (legacy_value->'value' ? plugin_id);

      INSERT INTO #{table} (scope, key, value, inserted_at, updated_at)
      VALUES (
        'global',
        'plugins.enabled_ids',
        jsonb_build_object('type', 'plaintext', 'value', migrated_enabled_ids),
        timezone('UTC', now()),
        timezone('UTC', now())
      );

      DELETE FROM #{table}
      WHERE key = 'plugins.disabled_ids';
    END
    $$
    """
  end

  defp validate_table!(table) do
    if is_binary(table) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, table) do
      table
    else
      raise ArgumentError, "invalid migration table name"
    end
  end
end
