defmodule Ankole.Repo.Migrations.RequireTenantOnRunnerBindings do
  use Ecto.Migration

  # A binding reached its tenant only through its device and its Agent. Every
  # tenant table states its ownership with a foreign key on `tenant_id` itself,
  # which is what the tenancy guard and tenant deletion read.
  def change do
    execute(
      """
      ALTER TABLE runner_bindings ADD CONSTRAINT runner_bindings_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants (id) ON DELETE RESTRICT
      """,
      "ALTER TABLE runner_bindings DROP CONSTRAINT runner_bindings_tenant_id_fkey"
    )
  end
end
