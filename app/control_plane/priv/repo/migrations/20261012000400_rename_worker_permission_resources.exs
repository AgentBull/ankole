defmodule Ankole.Repo.Migrations.RenameWorkerPermissionResources do
  use Ecto.Migration

  def up, do: rename_resources("agent_computer_workers", "agent_workers")
  def down, do: rename_resources("agent_workers", "agent_computer_workers")

  defp rename_resources(from, to) do
    # A grant already written with the new name has the same authorization
    # meaning. Keep it when both natural keys exist, then rename the remainder.
    execute("""
    DELETE FROM permission_grants old
    USING permission_grants current
    WHERE (old.resource_pattern = '#{from}' OR left(old.resource_pattern, #{String.length(from) + 1}) = '#{from}:')
      AND current.tenant_id = old.tenant_id
      AND current.principal_uid IS NOT DISTINCT FROM old.principal_uid
      AND current.group_id IS NOT DISTINCT FROM old.group_id
      AND current.action = old.action
      AND current.condition = old.condition
      AND current.resource_pattern = '#{to}' || substr(old.resource_pattern, #{String.length(from) + 1})
    """)

    execute("""
    UPDATE permission_grants
    SET resource_pattern = '#{to}' || substr(resource_pattern, #{String.length(from) + 1})
    WHERE resource_pattern = '#{from}' OR left(resource_pattern, #{String.length(from) + 1}) = '#{from}:'
    """)
  end
end
