defmodule Ankole.Pod.Properties do
  @moduledoc "Pod's optional display, ordering and document revision properties for a Drive node."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod

  postgres do
    table("pages")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)

    attribute(:title, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true, max_length: 255]
    )

    attribute(:icon, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:position, :string, constraints: [trim?: false])
    attribute(:revision, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:vfs_md_size, :integer, constraints: [min: 0])
    attribute(:vfs_md_blake3, :string)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:upstream_state, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:saved_from_message_id, Ankole.Ash.Types.UUIDv7)

    attribute(:children_view, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      constraints: [max_bytes: 1024]
    )

    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz, writable?: true)
    create_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz, writable?: true)
  end

  actions do
    defaults([:read])

    create_if_absent :ensure do
      accept([
        :id,
        :title,
        :icon,
        :position,
        :revision,
        :metadata,
        :upstream_state,
        :saved_from_message_id,
        :children_view,
        :created_at,
        :updated_at
      ])

      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :edit do
      accept([:title, :icon, :position, :children_view, :metadata, :updated_at])
      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :save_knowledge do
      require_atomic?(true)

      accept([
        :metadata,
        :upstream_state,
        :title,
        :icon,
        :updated_at,
        :vfs_md_size,
        :vfs_md_blake3
      ])

      change(atomic_update(:revision, expr(revision + 1)))
    end

    update :sync_upstream do
      require_atomic?(true)
      accept([:upstream_state])
    end

    update :position do
      require_atomic?(true)
      accept([:position])
    end

    update :advance_revision do
      require_atomic?(true)
      accept([:updated_at, :vfs_md_size, :vfs_md_blake3])
      change(atomic_update(:revision, expr(revision + 1)))
    end

    update :cache_vfs_projection do
      require_atomic?(true)
      accept([:vfs_md_size, :vfs_md_blake3])
    end

    destroy :remove do
      require_atomic?(true)
    end
  end
end
