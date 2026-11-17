defmodule Ankole.Repo.Migrations.AssignAssistantOwnedAppletsToOwners do
  use Ecto.Migration

  # A personal assistant is equivalent to its Human owner for Page ownership, so
  # Applets that an assistant created belong to that Human.
  def up do
    execute("""
    UPDATE pages AS page
    SET owner_uid = agent.owner_principal_uid
    FROM agents AS agent
    WHERE agent.tenant_id = page.tenant_id
      AND agent.uid = page.owner_uid
      AND agent.type = 'personal_assistant'
      AND agent.owner_principal_uid IS NOT NULL
    """)
  end

  def down, do: :ok
end
