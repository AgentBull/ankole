defmodule BullX.Repo.Migrations.AddPermissionGrantUpsertIndexes do
  use Ecto.Migration

  def change do
    create unique_index(
             :permission_grants,
             [:principal_id, :resource_pattern, :action, :condition],
             name: :permission_grants_principal_upsert_index,
             where: "principal_id IS NOT NULL"
           )

    create unique_index(:permission_grants, [:group_id, :resource_pattern, :action, :condition],
             name: :permission_grants_group_upsert_index,
             where: "group_id IS NOT NULL"
           )
  end
end
