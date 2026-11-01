defmodule Ankole.Pod.PodFile do
  @moduledoc "Owns a Pod asset path and its immutable tenant object reference."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod

  postgres do
    table("pod_files")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(path: "pod_files_path_index")
    foreign_key_names([{:node_id, "pod_files_node_fkey"}, {:object_id, "pod_files_object_fkey"}])

    check_constraints do
      check_constraint(:path, "pod_files_path_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:node_id, Ankole.Ash.Types.UUIDv7)
    attribute(:path, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

    attribute(:mode, :integer,
      allow_nil?: false,
      default: 0o644,
      constraints: [min: 0, max: 0o777]
    )

    attribute(:content_type, :string, allow_nil?: false)
    attribute(:source, :string, allow_nil?: false)
    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz)
    update_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz)
  end

  identities do
    identity(:path, [:node_id, :path], nils_distinct?: false)
  end

  relationships do
    belongs_to :object, Ankole.Files.Schemas.FileObject do
      source_attribute(:object_id)
      destination_attribute(:id)
      define_attribute?(false)
      allow_nil?(false)
    end
  end

  aggregates do
    first(:sha256, :object, :sha256)
    first(:size, :object, :size)
  end

  actions do
    defaults([:read])

    create :commit_in_tx do
      transaction?(false)
      accept([:node_id, :path, :object_id, :mode, :content_type, :source])
      upsert?(true)
      upsert_identity(:path)
      upsert_fields([:object_id, :mode, :content_type, :source, :updated_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
