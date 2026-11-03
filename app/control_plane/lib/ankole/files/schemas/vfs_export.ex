defmodule Ankole.Files.Schemas.VfsExport do
  @moduledoc "A short-lived immutable Base export referenced by PostgreSQL."
  use Ankole.Ash.Resource, tenancy: :tenant, tenant_in_primary_key: true, domain: Ankole.Files

  postgres do
    table("drive_vfs_exports")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:snapshot_key, :string, allow_nil?: false)
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:expires_at, Ankole.Ash.Types.Timestamptz, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      transaction?(false)
      accept([:snapshot_key, :object_id, :expires_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
