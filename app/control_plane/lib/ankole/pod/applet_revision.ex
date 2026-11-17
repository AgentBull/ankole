defmodule Ankole.Pod.AppletRevision do
  @moduledoc "An immutable published Applet snapshot or the page's current draft."
  use Ankole.Ash.Resource, tenancy: :tenant, tenant_in_primary_key: true, domain: Ankole.Pod

  postgres do
    table("pod_applet_revisions")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "pod_applet_revisions_page_fkey"}])

    unique_index_names([
      {[:page_id, :revision], "pod_applet_revisions_tenant_id_page_id_revision_index"},
      {[:page_id], "pod_applet_revisions_draft_index"}
    ])

    check_constraints do
      check_constraint(:revision, "pod_applet_revisions_state")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:is_draft, :boolean, allow_nil?: false, default: false)
    attribute(:revision, :integer, constraints: [min: 1])
    attribute(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:summary, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:published_by, Ankole.Ash.Types.PrincipalKey)
    attribute(:routes_signature, Ankole.Ash.Types.JSONValue, allow_nil?: false, default: [])
    attribute(:actions_signature, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:restored_from_revision, :integer, constraints: [min: 1])
    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz)
    update_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz)
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      transaction?(false)

      accept([
        :page_id,
        :is_draft,
        :revision,
        :base_revision,
        :summary,
        :published_by,
        :routes_signature,
        :actions_signature,
        :restored_from_revision
      ])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end

    destroy :purge do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
