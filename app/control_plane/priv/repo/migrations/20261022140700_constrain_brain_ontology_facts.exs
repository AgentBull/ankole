defmodule Ankole.Repo.Migrations.ConstrainBrainOntologyFacts do
  use Ecto.Migration

  def up do
    create constraint(:brain_schema_types, :brain_schema_types_subtypes_strings,
             check:
               ~s|jsonb_typeof(subtypes) = 'array' AND NOT jsonb_path_exists(subtypes, '$[*] ? (@.type() != "string")')|
           )

    create unique_index(:brain_claims, [:tenant_id, :id])

    execute(
      "ALTER TABLE brain_take_domain_assignments DROP CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey"
    )

    execute(
      "ALTER TABLE brain_take_domain_assignments ADD CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey FOREIGN KEY (tenant_id, take_claim_id) REFERENCES brain_claims(tenant_id, id) ON DELETE CASCADE"
    )
  end

  def down do
    execute(
      "ALTER TABLE brain_take_domain_assignments DROP CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey"
    )

    execute(
      "ALTER TABLE brain_take_domain_assignments ADD CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey FOREIGN KEY (take_claim_id) REFERENCES brain_claims(id) ON DELETE CASCADE"
    )

    drop index(:brain_claims, [:tenant_id, :id])
    drop constraint(:brain_schema_types, :brain_schema_types_subtypes_strings)
  end
end
