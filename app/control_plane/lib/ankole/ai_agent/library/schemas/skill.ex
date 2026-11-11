defmodule Ankole.AIAgent.Library.Schemas.Skill do
  @moduledoc "A tenant Skill package, including its required manifest and enablement policy."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AIAgent

  postgres do
    table("skills")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:agent_uid, "skills_agent_uid_fkey"}])
    identity_index_names(slug: "skills_tenant_id_slug_key")

    check_constraints do
      check_constraint(:agent_uid, "skills_private_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:slug, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[a-z0-9][a-z0-9._-]{0,95}\z/]
    )

    attribute(:name, :string, allow_nil?: false)
    attribute(:description, :string, allow_nil?: false)

    attribute(:manifest_xml, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:manifest_markdown, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:enabled_for_all, :boolean, allow_nil?: false, default: false)

    attribute(:source_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:builtin, :agent_plugin, :custom]]
    )

    attribute(:agent_plugin_id, :string)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:revision, :integer, allow_nil?: false, default: 1)
    attribute(:upstream_state, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:created_by, Ankole.Ash.Types.PrincipalKey)
    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz)
    update_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz)
  end

  identities do
    identity(:slug, [:slug])
  end

  actions do
    defaults([:read])

    create :create do
      transaction?(false)

      accept([
        :id,
        :slug,
        :name,
        :description,
        :manifest_xml,
        :manifest_markdown,
        :metadata,
        :enabled_for_all,
        :source_kind,
        :agent_plugin_id,
        :agent_uid,
        :upstream_state,
        :created_by
      ])
    end

    update :save do
      transaction?(false)
      require_atomic?(true)
      argument(:base_revision, :integer, allow_nil?: false)

      accept([
        :slug,
        :name,
        :description,
        :manifest_xml,
        :manifest_markdown,
        :metadata,
        :enabled_for_all,
        :agent_uid,
        :upstream_state
      ])

      change(filter(expr(revision == ^arg(:base_revision))))
      change(atomic_update(:revision, expr(revision + 1)))
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
