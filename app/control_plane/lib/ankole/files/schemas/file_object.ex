defmodule Ankole.Files.Schemas.FileObject do
  @moduledoc "An immutable object owned by one tenant, including uploads awaiting a reference."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Files

  postgres do
    table("file_objects")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(storage_key: "file_objects_storage_key_index")

    check_constraints do
      check_constraint(:sha256, "file_objects_completion_shape")
      check_constraint(:size, "file_objects_completion_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:storage_key, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:sha256, :binary)
    attribute(:size, :integer, constraints: [min: 0])
    attribute(:completed_at, Ankole.Ash.Types.Timestamptz)
    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz, writable?: true)
  end

  identities do
    identity(:storage_key, [:storage_key], all_tenants?: true)
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      transaction?(false)
      accept([:id, :storage_key, :created_at])
    end

    update :complete_in_tx do
      transaction?(false)
      require_atomic?(false)
      accept([:sha256, :size, :completed_at])
      change(filter(expr(is_nil(completed_at))))
      validate(byte_size(:sha256, exact: 32))
      validate(present([:sha256, :size, :completed_at]))
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
