defmodule Ankole.Pod.AppletRevisionFile do
  @moduledoc "A revision's immutable artifact reference, retained until that revision is removed."
  use Ankole.Ash.Resource, tenancy: :tenant, tenant_in_primary_key: true, domain: Ankole.Pod

  postgres do
    table("pod_applet_revision_files")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:revision_id, "pod_applet_revision_files_revision_fkey"},
      {:object_id, "pod_applet_revision_files_object_fkey"}
    ])
  end

  attributes do
    attribute(:revision_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:path, :string, primary_key?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:content_type, :string, allow_nil?: false)

    attribute(:mode, :integer,
      allow_nil?: false,
      default: 0o644,
      constraints: [min: 0, max: 0o777]
    )
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

    create :create_in_tx do
      transaction?(false)
      accept([:revision_id, :path, :object_id, :content_type, :mode])
    end
  end
end
