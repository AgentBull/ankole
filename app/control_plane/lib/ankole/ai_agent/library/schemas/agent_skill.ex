defmodule Ankole.AIAgent.Library.Schemas.AgentSkill do
  @moduledoc "Per-Agent Skill registry metadata; Skill bytes remain in their filesystem bundles."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIAgent

  postgres do
    table("agent_skills")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(agent_skill: "agent_skills_agent_skill_index")
    foreign_key_names(agent_uid: "agent_skills_agent_uid_fkey")

    check_constraints do
      check_constraint(:skill_name, "agent_skills_skill_name_format")
      check_constraint(:source_kind, "agent_skills_source_kind_check")
      check_constraint(:agent_plugin_id, "agent_skills_agent_plugin_id_format")
      check_constraint(:relative_path, "agent_skills_relative_path_present")
      check_constraint(:description, "agent_skills_description_present")
      check_constraint(:metadata, "agent_skills_metadata_object")
      check_constraint(:content_hash, "agent_skills_content_hash_present")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)

    attribute(:skill_name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:source_kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:builtin, :installed]]
    )

    attribute(:agent_plugin_id, :string,
      public?: true,
      constraints: [match: ~r/\A[a-z][a-z0-9_-]{0,63}\z/]
    )

    attribute(:relative_path, :string, allow_nil?: false, public?: true)
    attribute(:enabled_override, :boolean, public?: true)
    attribute(:default_enabled, :boolean, allow_nil?: false, public?: true)

    attribute(:description, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 1024]
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true,
      constraints: [allow_datetime?: true]
    )

    attribute(:content_hash, :string, allow_nil?: false, public?: true)
    attribute(:synced_at, :utc_datetime_usec, public?: true)
    create_timestamp(:inserted_at, type: :utc_datetime_usec, writable?: true)
    update_timestamp(:updated_at, type: :utc_datetime_usec, writable?: true)
  end

  identities do
    identity(:agent_skill, [:agent_uid, :skill_name])
  end

  actions do
    defaults([:read])

    create :sync do
      accept([
        :agent_uid,
        :skill_name,
        :source_kind,
        :agent_plugin_id,
        :relative_path,
        :default_enabled,
        :description,
        :metadata,
        :content_hash,
        :synced_at,
        :inserted_at,
        :updated_at
      ])

      upsert?(true)
      upsert_identity(:agent_skill)

      upsert_fields([
        :source_kind,
        :agent_plugin_id,
        :relative_path,
        :default_enabled,
        :description,
        :metadata,
        :content_hash,
        :synced_at,
        :updated_at
      ])

      change(Ankole.AIAgent.Library.Changes.PrepareSkill, only_when_valid?: true)
    end

    update :set_override do
      accept([:enabled_override])
      require_atomic?(true)
    end

    destroy :remove_stale do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
