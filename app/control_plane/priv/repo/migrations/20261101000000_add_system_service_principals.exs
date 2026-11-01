defmodule Ankole.Repo.Migrations.AddSystemServicePrincipals do
  use Ecto.Migration

  def up do
    drop(index(:principals, [:tenant_id], name: :principals_one_system_per_tenant_index))

    drop constraint(:app_configurations, :app_configurations_scope_check)

    create constraint(:app_configurations, :app_configurations_scope_check,
             check:
               "scope = 'tenant:' || tenant_id::text OR scope ~ '^agent:.+' OR scope IN ('system:system', 'system:ankole_brain')"
           )

    execute("""
    INSERT INTO principals (
      tenant_id, uid, type, status, access_version, display_name, inserted_at, updated_at
    )
    SELECT id, 'ankole_brain', 'system', 'active', 1, 'Ankole Brain', now(), now()
    FROM tenants
    """)

    alter table(:brain_claims) do
      add :graded_by, :text
    end

    create constraint(:brain_claims, :brain_claims_grader_shape,
             check:
               "graded_by IS NULL OR (claim_type = 'take' AND graded_at IS NOT NULL AND btrim(graded_by) <> '')"
           )
  end

  def down do
    raise Ecto.MigrationError,
          "System service Principals own usage and Brain audit records. Restore a pre-upgrade database backup to run the previous version."
  end
end
