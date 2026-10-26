defmodule Ankole.AIAgent.Library.AgentPlugins.Schemas.AgentPluginOverride do
  @moduledoc "One sparse Agent Plugin enablement override."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIAgent

  postgres do
    table("agent_plugin_overrides")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(agent_plugin: "agent_plugin_overrides_agent_plugin_index")
    foreign_key_names(agent_uid: "agent_plugin_overrides_agent_uid_fkey")

    check_constraints do
      check_constraint(:agent_plugin_id, "agent_plugin_overrides_agent_plugin_id_format")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)

    attribute(:agent_plugin_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[a-z][a-z0-9_-]{0,63}\z/]
    )

    attribute(:enabled, :boolean, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  identities do
    identity(:agent_plugin, [:agent_uid, :agent_plugin_id], all_tenants?: true)
  end

  actions do
    defaults([:read])

    create :set do
      accept([:agent_uid, :agent_plugin_id, :enabled])
      upsert?(true)
      upsert_identity(:agent_plugin)
      upsert_fields([:enabled, :updated_at])
    end

    destroy :reset do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
