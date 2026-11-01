defmodule Ankole.Repo.Migrations.ScopePrincipalNames do
  use Ecto.Migration

  def up do
    alter table(:agents) do
      remove :handle
    end

    drop constraint(:agents, :agents_uid_agent_home_safe)

    create constraint(:agents, :agents_uid_agent_home_safe,
             check: "uid ~ '^[a-z0-9][a-z0-9._@+-]{0,95}$'"
           )

    create constraint(:agents, :personal_assistant_strict_memory,
             check: "type <> 'personal_assistant' OR group_memory_disclosure_mode = 'strict'"
           )

    create unique_index(:agents, [:tenant_id, :owner_principal_uid],
             where: "type = 'personal_assistant'",
             name: :agents_personal_assistant_owner_index
           )

    create unique_index(:agent_workers, [:token_digest], where: "token_digest IS NOT NULL")
  end

  def down do
    raise "Tenant-local names cannot be converted to globally unique names automatically"
  end
end
