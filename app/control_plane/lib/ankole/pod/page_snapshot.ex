defmodule Ankole.Pod.PageSnapshot do
  @moduledoc "An immutable document checkpoint subject to document history retention."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

  postgres do
    table("page_snapshots")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "page_snapshots_tenant_id_page_id_fkey"}])
    unique_index_names([{[:id], "page_snapshots_pkey"}])

    check_constraints do
      check_constraint(:reason, "page_snapshots_reason_check")
      check_constraint(:revision, "page_snapshots_revision_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:title, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:icon, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:content, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:author, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:document_updated_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)

    attribute(:reason, :atom,
      allow_nil?: false,
      constraints: [one_of: [:created, :baseline, :checkpoint, :before_restore, :restored]]
    )
  end

  actions do
    defaults([:read])

    read :list do
      pagination(keyset?: true, max_page_size: 100, countable: false, required?: false)
    end

    create :append do
      accept([
        :page_id,
        :revision,
        :title,
        :icon,
        :content,
        :author,
        :document_updated_at,
        :created_at,
        :reason
      ])
    end

    destroy :purge do
      require_atomic?(true)
    end

    update :rename_mentions do
      accept([:content])
    end
  end

  @type t :: %__MODULE__{}
end
