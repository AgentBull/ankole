defmodule Ankole.Repo.Migrations.MoveFileGrantsToAgentDrives do
  use Ecto.Migration

  # The Console file API moved from one Worker (`agent_computer_worker:<id>:files`)
  # to one Agent's drive (`agent:<uid>:files`). A grant for every Worker becomes
  # a grant for every Agent; when its owner already holds the same Agent grant,
  # the Worker grant is only removed. A grant for one Worker names no Agent, so
  # it has no successor and is removed; so is every other
  # `agent_computer_worker:` pattern, for example `agent_computer_worker:*:*`,
  # because the pooled Workers that it named no longer exist.
  def up do
    execute(fn ->
      %{rows: grants} =
        repo().query!("""
        SELECT DISTINCT ON (principal_uid, group_id, action, condition) id
        FROM permission_grants
        WHERE resource_pattern IN ('agent_computer_worker:*:files', 'agent_computer_worker:**')
          AND action IN ('read', 'update', 'delete')
        ORDER BY principal_uid, group_id, action, condition, id
        """)

      Enum.each(grants, fn [source_id] ->
        repo().query!(
          """
          INSERT INTO permission_grants
            (id, principal_uid, group_id, resource_pattern, action, condition, description, metadata,
             inserted_at, updated_at)
          SELECT $1::uuid, principal_uid, group_id, 'agent:*:files', action, condition,
            description, metadata, now(), now()
          FROM permission_grants WHERE id = $2::uuid
          ON CONFLICT DO NOTHING
          """,
          [Ecto.UUID.dump!(Ankole.Kernel.gen_uuid_v7()), source_id]
        )
      end)
    end)

    execute """
    DELETE FROM permission_grants
    WHERE resource_pattern LIKE 'agent_computer_worker:%'
    """
  end

  def down do
    raise Ecto.MigrationError, message: "Worker file grants have no Agent drive equivalent"
  end
end
