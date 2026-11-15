defmodule Ankole.Repo.Migrations.MergeCodingModelProfileIntoHeavy do
  use Ecto.Migration

  # Background Agent Jobs and complex reasoning work share the `heavy` model
  # profile slot (`heavy -> primary`). Stored `coding` overrides move into
  # `heavy` wherever `heavy` is not already configured in the same scope, and
  # persisted work rows rewrite `coding` to `heavy` so continuations inherit a
  # valid fixed tier.
  def up do
    execute("""
    INSERT INTO site_app_configurations (scope, key, value, inserted_at, updated_at)
    SELECT scope, 'ai_gateway.model_profiles.heavy', value, inserted_at, updated_at
    FROM site_app_configurations
    WHERE scope = 'global'
      AND key = 'ai_gateway.model_profiles.coding'
      AND jsonb_typeof(value -> 'value') = 'object'
    ON CONFLICT (scope, key) DO UPDATE
    SET value = EXCLUDED.value,
        updated_at = EXCLUDED.updated_at
    WHERE jsonb_typeof(site_app_configurations.value -> 'value') IS DISTINCT FROM 'object'
    """)

    execute("DELETE FROM site_app_configurations WHERE key = 'ai_gateway.model_profiles.coding'")

    execute("""
    INSERT INTO app_configurations (tenant_id, scope, key, value, inserted_at, updated_at)
    SELECT tenant_id, scope, 'ai_gateway.model_profiles.heavy', value, inserted_at, updated_at
    FROM app_configurations
    WHERE key = 'ai_gateway.model_profiles.coding'
      AND jsonb_typeof(value -> 'value') = 'object'
    ON CONFLICT (tenant_id, scope, key) DO UPDATE
    SET value = EXCLUDED.value,
        updated_at = EXCLUDED.updated_at
    WHERE jsonb_typeof(app_configurations.value -> 'value') IS DISTINCT FROM 'object'
    """)

    execute("DELETE FROM app_configurations WHERE key = 'ai_gateway.model_profiles.coding'")

    execute("""
    UPDATE agents
    SET options = jsonb_set(
      options,
      '{ai_agent,models}',
      (
        CASE
          WHEN jsonb_typeof(options #> '{ai_agent,models,heavy}') IS DISTINCT FROM 'object'
           AND jsonb_typeof(options #> '{ai_agent,models,coding}') = 'object'
          THEN jsonb_set(
            options #> '{ai_agent,models}',
            '{heavy}',
            options #> '{ai_agent,models,coding}',
            true
          )
          ELSE options #> '{ai_agent,models}'
        END
      ) - 'coding',
      true
    )
    WHERE jsonb_typeof(options #> '{ai_agent,models}') = 'object'
      AND (options #> '{ai_agent,models}') ? 'coding'
    """)

    execute("ALTER TABLE background_agent_jobs ALTER COLUMN model_profile SET DEFAULT 'heavy'")

    execute(
      "UPDATE background_agent_jobs SET model_profile = 'heavy' WHERE model_profile = 'coding'"
    )

    execute("UPDATE workflow_runs SET model_profile = 'heavy' WHERE model_profile = 'coding'")

    execute(
      "UPDATE workflow_agent_calls SET model_profile = 'heavy' WHERE model_profile = 'coding'"
    )
  end

  # `heavy` was already a valid slot, so migrated rows cannot be separated from
  # rows that originally selected `heavy`.
  def down do
    execute("ALTER TABLE background_agent_jobs ALTER COLUMN model_profile SET DEFAULT 'coding'")
  end
end
