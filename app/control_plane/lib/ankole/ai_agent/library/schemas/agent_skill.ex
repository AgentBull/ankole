defmodule Ankole.AIAgent.Library.Schemas.AgentSkill do
  @moduledoc "An explicit positive Skill binding for one Agent."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AIAgent

  postgres do
    table("agent_skills")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, primary_key?: true, allow_nil?: false)
    attribute(:skill_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz)
  end

  actions do
    defaults([:read])

    create :enable do
      transaction?(false)
      accept([:agent_uid, :skill_id])
      upsert?(true)
      upsert_fields([])
    end

    destroy :disable do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
