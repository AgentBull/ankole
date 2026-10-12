defmodule Ankole.Repo.Migrations.SplitSiteConfigurationRows do
  use Ecto.Migration

  @tables [
    {"app_configurations", "site_app_configurations", "key"},
    {"agent_computer_worker_envs", "site_worker_envs", "name"}
  ]

  def up do
    for {tenant, site, key} <- @tables do
      execute("CREATE TABLE #{site} (LIKE #{tenant} INCLUDING DEFAULTS)")
      execute("ALTER TABLE #{site} DROP COLUMN tenant_id")
      execute("ALTER TABLE #{site} ADD CONSTRAINT #{site}_scope_check CHECK (scope = 'global')")
      execute("CREATE UNIQUE INDEX #{site}_scope_#{key}_unique ON #{site} (scope, #{key})")

      columns =
        if key == "key",
          do: "scope,key,value,inserted_at,updated_at",
          else: "scope,name,secret,value,description,inserted_at,updated_at"

      # Scope and key are AEAD inputs. Move the stored envelope without changing either.
      execute(
        "INSERT INTO #{site} (#{columns}) SELECT #{columns} FROM #{tenant} WHERE scope = 'global'"
      )

      execute("DELETE FROM #{tenant} WHERE scope = 'global'")
      execute("ALTER TABLE #{tenant} DROP CONSTRAINT #{tenant}_tenant_scope_check")
      execute("ALTER TABLE #{tenant} DROP CONSTRAINT #{tenant}_scope_check")
      execute("ALTER TABLE #{tenant} ALTER COLUMN tenant_id SET NOT NULL")

      execute(
        "ALTER TABLE #{tenant} ADD CONSTRAINT #{tenant}_scope_check CHECK (scope = 'tenant:' || tenant_id::text OR scope ~ '^agent:.+$')"
      )

      execute("DROP INDEX #{tenant}_scope_#{key}_unique")

      execute(
        "CREATE UNIQUE INDEX #{tenant}_scope_#{key}_unique ON #{tenant} (tenant_id, scope, #{key})"
      )
    end

    execute(
      "ALTER TABLE site_worker_envs ADD CONSTRAINT site_worker_envs_name_check CHECK (name ~ '^[A-Za-z_][A-Za-z0-9_]*$')"
    )

    execute(
      "ALTER TABLE site_app_configurations ADD CONSTRAINT site_app_configurations_value_envelope_check CHECK (jsonb_typeof(value) = 'object' AND value->>'type' IN ('plaintext','cipher') AND value ? 'value')"
    )
  end

  def down do
    for {tenant, site, key} <- @tables do
      execute("ALTER TABLE #{tenant} DROP CONSTRAINT #{tenant}_scope_check")
      execute("ALTER TABLE #{tenant} ALTER COLUMN tenant_id DROP NOT NULL")

      execute(
        "ALTER TABLE #{tenant} ADD CONSTRAINT #{tenant}_scope_check CHECK (scope = 'global' OR scope ~ '^agent:.+$' OR scope ~ '^tenant:[0-9a-f-]{36}$')"
      )

      execute(
        "ALTER TABLE #{tenant} ADD CONSTRAINT #{tenant}_tenant_scope_check CHECK ((scope = 'global') = (tenant_id IS NULL))"
      )

      execute("DROP INDEX #{tenant}_scope_#{key}_unique")
      execute("CREATE UNIQUE INDEX #{tenant}_scope_#{key}_unique ON #{tenant} (scope, #{key})")

      columns =
        if key == "key",
          do: "scope,key,value,inserted_at,updated_at",
          else: "scope,name,secret,value,description,inserted_at,updated_at"

      execute("INSERT INTO #{tenant} (#{columns}) SELECT #{columns} FROM #{site}")
      execute("DROP TABLE #{site}")
    end
  end
end
