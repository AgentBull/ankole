defmodule BullX.Repo.Migrations.AllowAuthzResourceGlobs do
  use Ecto.Migration

  def up do
    drop constraint(:permission_grants, :permission_grants_resource_pattern_wildcards)
  end

  def down do
    create constraint(:permission_grants, :permission_grants_resource_pattern_wildcards,
             check: "(length(resource_pattern) - length(replace(resource_pattern, '*', ''))) <= 1"
           )
  end
end
