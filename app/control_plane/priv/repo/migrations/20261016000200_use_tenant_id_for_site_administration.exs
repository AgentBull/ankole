defmodule Ankole.Repo.Migrations.UseTenantIdForSiteAdministration do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      assignment jsonb;
      tenant_id uuid;
    BEGIN
      SELECT value INTO assignment
      FROM site_app_configurations
      WHERE scope = 'global' AND key = 'tenants.privileged_slug'
      FOR UPDATE;

      IF NOT FOUND OR assignment->>'type' IS DISTINCT FROM 'plaintext'
         OR jsonb_typeof(assignment->'value') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Site administration requires a valid tenants.privileged_slug before upgrade';
      END IF;

      SELECT id INTO tenant_id FROM tenants WHERE slug = assignment->>'value';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Site administration tenant does not exist: %', assignment->>'value';
      END IF;

      UPDATE site_app_configurations
      SET key = 'tenants.privileged_tenant_id',
          value = jsonb_build_object('type', 'plaintext', 'value', tenant_id::text),
          updated_at = now()
      WHERE scope = 'global' AND key = 'tenants.privileged_slug';
    END $$;
    """)
  end

  def down do
    raise "Restore the pre-upgrade backup to recover the slug-based site administration assignment."
  end
end
