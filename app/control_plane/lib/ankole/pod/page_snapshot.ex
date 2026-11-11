defmodule Ankole.Pod.PageSnapshot do
  @moduledoc """
  An immutable page checkpoint subject to page history retention.

  A document snapshot carries its XML `content`; an Office file snapshot names
  the file object that held the file, and that reference keeps the object
  alive.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

  postgres do
    table("page_snapshots")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:page_id, "page_snapshots_tenant_id_page_id_fkey"},
      {:object_id, "page_snapshots_object_fkey"}
    ])

    unique_index_names([{[:id], "page_snapshots_pkey"}])

    check_constraints do
      check_constraint(:reason, "page_snapshots_reason_check")
      check_constraint(:revision, "page_snapshots_revision_check")
      check_constraint(:content, "page_snapshots_content_shape")
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
    attribute(:metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:content, :string, constraints: [trim?: false])
    attribute(:object_id, Ankole.Ash.Types.UUIDv7)
    attribute(:author, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:document_updated_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)

    attribute(:reason, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [:created, :baseline, :checkpoint, :uploaded, :before_restore, :restored]
      ]
    )
  end

  relationships do
    belongs_to :page, Ankole.Pod.Page do
      define_attribute?(false)
      source_attribute(:page_id)
    end

    belongs_to :object, Ankole.Files.Schemas.FileObject do
      source_attribute(:object_id)
      destination_attribute(:id)
      define_attribute?(false)
    end
  end

  aggregates do
    first(:sha256, :object, :sha256)
    first(:size, :object, :size)
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
        :object_id,
        :metadata,
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
