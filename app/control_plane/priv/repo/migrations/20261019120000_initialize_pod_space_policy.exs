defmodule Ankole.Repo.Migrations.InitializePodSpacePolicy do
  use Ecto.Migration

  @all_humans_condition ~s(principal.type == "human" && principal.status == "active")

  def up do
    execute(fn ->
      # Freeze this historical policy. Runtime setup belongs to Pod.Access.
      # Existing Pod content or policy is authoritative, including revoked grants.
      %{rows: tenants} =
        repo().query!("""
        SELECT t.id FROM tenants t
        WHERE NOT EXISTS (SELECT 1 FROM pages p WHERE p.tenant_id = t.id)
          AND NOT EXISTS (
            SELECT 1 FROM permission_grants g
            WHERE g.tenant_id = t.id AND g.action LIKE 'page\\_%' ESCAPE '\\'
          )
        """)

      for [tenant_id] <- tenants do
        group_id = all_humans_group!(tenant_id)

        for action <- ~w(page_view page_edit page_manage) do
          repo().query!(
            """
            INSERT INTO permission_grants
              (id, tenant_id, group_id, resource_pattern, action, condition, metadata,
               inserted_at, updated_at)
            VALUES ($1, $2, $3, 'pod:space:**', $4, 'true', '{}', now(), now())
            """,
            [uuid(), tenant_id, group_id, action]
          )
        end
      end
    end)
  end

  defp all_humans_group!(tenant_id) do
    repo().query!(
      """
      INSERT INTO principal_groups
        (id, tenant_id, name, display_name, domain, kind, built_in, computed_condition,
         description, metadata, inserted_at, updated_at)
      VALUES ($1, $2, 'all_humans', 'All Humans', 'operator', 'computed', true, $3,
              'Computed group for active human Principals', '{}', now(), now())
      ON CONFLICT (tenant_id, name) DO NOTHING
      """,
      [uuid(), tenant_id, @all_humans_condition]
    )

    case repo().query!(
           """
           SELECT id, kind::text, built_in, computed_condition FROM principal_groups
           WHERE tenant_id = $1 AND name = 'all_humans'
           """,
           [tenant_id]
         ).rows do
      [[id, "computed", true, @all_humans_condition]] -> id
      _ -> raise "Pod policy migration requires the built-in all_humans group"
    end
  end

  defp uuid, do: Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())

  # A rollback must not remove a policy that an operator can have changed.
  def down, do: :ok
end
