defmodule Ankole.AIAgent.Library.Schemas.AgentContract do
  @moduledoc "A global baseline or an individual Agent instruction contract."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AIAgent

  postgres do
    table("agent_contracts")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:slot, :atom, allow_nil?: false, constraints: [one_of: [:agents, :design]])

    attribute(:mode, :atom,
      allow_nil?: false,
      constraints: [one_of: [:inherit, :append, :override]]
    )

    attribute(:content_xml, :string,
      allow_nil?: false,
      default: "<page />",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:content_markdown, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:revision, :integer, allow_nil?: false, default: 1)
    attribute(:upstream_state, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:updated_by, Ankole.Ash.Types.PrincipalKey)
    update_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz)
  end

  actions do
    defaults([:read])

    create :create do
      transaction?(false)

      accept([
        :id,
        :agent_uid,
        :slot,
        :mode,
        :content_xml,
        :content_markdown,
        :metadata,
        :upstream_state,
        :updated_by
      ])
    end

    update :save do
      transaction?(false)
      require_atomic?(true)
      argument(:base_revision, :integer, allow_nil?: false)
      accept([:mode, :content_xml, :content_markdown, :metadata, :upstream_state, :updated_by])
      change(filter(expr(revision == ^arg(:base_revision))))
      change(atomic_update(:revision, expr(revision + 1)))
    end
  end
end
