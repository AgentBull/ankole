defmodule Ankole.Pod.Page do
  @moduledoc "Owns a Page identity, content type, tree position, permissions and lifecycle."
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:read, check: :page_filter)
    allow(:list_children, check: :page_filter)
    allow(:list_roots, check: :page_filter)
    allow(:search, check: :page_filter)
  end

  json_api do
    type("pod_page")

    primary_key do
      keys([:id])
    end

    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("pages")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:parent_id, "pages_parent_fkey"},
      {:object_id, "pages_object_fkey"},
      {:private_owner_uid, "pages_private_owner_fkey"},
      {:conversation_id, "pages_conversation_fkey"}
    ])

    check_constraints do
      check_constraint(:name, "pages_name_shape")
      check_constraint(:mode, "pages_mode")
      check_constraint(:type, "pages_type")
      check_constraint(:object_id, "pages_object_shape")
      check_constraint(:acl_anchor_id, "pages_acl_anchor_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:name, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:is_root, :boolean, public?: true, generated?: true, writable?: false)
    attribute(:parent_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:private_owner_uid, Ankole.Ash.Types.PrincipalKey, public?: true)
    attribute(:owner_uid, Ankole.Ash.Types.PrincipalKey, public?: true)

    attribute(:type, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:doc, :knowledge, :base, :applet, :file]]
    )

    attribute(:title, :string,
      public?: true,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true, max_length: 255]
    )

    attribute(:icon, :string, public?: true, constraints: [trim?: false, allow_empty?: true])
    attribute(:position, :string, public?: true, constraints: [trim?: false])
    attribute(:inherit_permissions, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:has_local_acl, :boolean, allow_nil?: false, default: false)
    attribute(:is_acl_anchor, :boolean, allow_nil?: false, generated?: true, writable?: false)
    attribute(:acl_anchor_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:parent_anchor_id, Ankole.Ash.Types.UUIDv7)

    attribute(:revision, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    attribute(:upstream_state, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:system_key, :string, public?: true)

    attribute(:saved_from_message_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:children_view, Ankole.Ash.Types.JSONMap,
      public?: true,
      allow_nil?: false,
      default: %{},
      constraints: [max_bytes: 1024]
    )

    attribute(:created_by, Ankole.Ash.Types.ActorRef)
    attribute(:deleted_at, Ankole.Ash.Types.Timestamptz, public?: true)
    attribute(:purge_started_at, Ankole.Ash.Types.Timestamptz, public?: true)

    create_timestamp(:created_at,
      type: Ankole.Ash.Types.Timestamptz,
      public?: true,
      writable?: true
    )

    create_timestamp(:updated_at,
      type: Ankole.Ash.Types.Timestamptz,
      public?: true,
      writable?: true
    )

    attribute(:vfs_md_size, :integer, constraints: [min: 0])
    attribute(:vfs_md_blake3, :string)
    attribute(:vfs_content_empty, :boolean, default: true)
    attribute(:last_vfs_req_id, :uuid)
    attribute(:last_vfs_etag, :string)

    attribute(:mode, :integer,
      allow_nil?: false,
      default: 0o644,
      constraints: [min: 0, max: 0o777]
    )

    attribute(:content_type, :string)
    attribute(:source, :string)
    attribute(:message_id, Ankole.Ash.Types.UUIDv7)
    attribute(:source_conversation_id, Ankole.Ash.Types.UUIDv7)
  end

  calculations do
    calculate(:actions, {:array, :atom}, expr(nil),
      public?: true,
      constraints: [
        items: [
          one_of: [:node_view, :node_contribute, :node_edit, :node_manage, :node_comment]
        ]
      ]
    )

    calculate(:role, :atom, expr(nil),
      public?: true,
      constraints: [one_of: [:view, :contribute, :edit, :manage]]
    )

    calculate(:visited_at, Ankole.Ash.Types.Timestamptz, expr(nil), public?: true)
  end

  relationships do
    belongs_to :saved_from_message, Ankole.Conversations.Message do
      define_attribute?(false)
      source_attribute(:saved_from_message_id)
    end

    has_many :children, __MODULE__ do
      source_attribute(:id)
      destination_attribute(:parent_id)
    end

    has_one :content, Ankole.Pod.PageContent do
      source_attribute(:id)
      destination_attribute(:page_id)
    end

    has_one :file_cache, Ankole.Pod.FileCache do
      source_attribute(:id)
      destination_attribute(:page_id)
    end

    has_one :search_document, Ankole.Pod.PageSearchDocument do
      source_attribute(:id)
      destination_attribute(:page_id)
    end
  end

  actions do
    defaults([:read])

    read :list_page do
      pagination(offset?: true, max_page_size: 5000, countable: false)
    end

    create :create_in_tx do
      transaction?(false)

      accept([
        :id,
        :parent_id,
        :name,
        :type,
        :system_key,
        :private_owner_uid,
        :conversation_id,
        :inherit_permissions,
        :has_local_acl,
        :acl_anchor_id,
        :parent_anchor_id,
        :object_id,
        :last_vfs_req_id,
        :last_vfs_etag,
        :mode,
        :content_type,
        :source,
        :message_id,
        :source_conversation_id,
        :created_by,
        :owner_uid,
        :deleted_at,
        :purge_started_at,
        :created_at,
        :updated_at,
        :title,
        :icon,
        :position,
        :metadata,
        :saved_from_message_id,
        :children_view,
        :vfs_md_size,
        :vfs_md_blake3,
        :vfs_content_empty
      ])

      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :update_in_tx do
      transaction?(false)
      require_atomic?(false)

      accept([
        :parent_id,
        :name,
        :inherit_permissions,
        :has_local_acl,
        :acl_anchor_id,
        :parent_anchor_id,
        :object_id,
        :last_vfs_req_id,
        :last_vfs_etag,
        :mode,
        :content_type,
        :source,
        :message_id,
        :source_conversation_id,
        :deleted_at,
        :purge_started_at,
        :updated_at,
        :title
      ])
    end

    update :claim_system do
      transaction?(false)
      require_atomic?(false)
      accept([:system_key])
    end

    update :transfer_owner do
      transaction?(false)
      accept([:owner_uid])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end

    update :initialize_metadata do
      transaction?(false)
      require_atomic?(false)

      accept([
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
      transaction?(false)
      accept([:title, :icon, :position, :children_view, :metadata, :updated_at])
      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :save_knowledge do
      transaction?(false)
      require_atomic?(true)

      accept([
        :metadata,
        :upstream_state,
        :title,
        :icon,
        :updated_at,
        :vfs_md_size,
        :vfs_md_blake3,
        :vfs_content_empty
      ])

      change(atomic_update(:revision, expr(revision + 1)))
    end

    update :sync_upstream do
      transaction?(false)
      require_atomic?(true)
      accept([:upstream_state])
    end

    update :position do
      transaction?(false)
      require_atomic?(true)
      accept([:position])
    end

    update :advance_revision do
      transaction?(false)
      require_atomic?(true)
      accept([:updated_at, :vfs_md_size, :vfs_md_blake3, :vfs_content_empty])
      change(atomic_update(:revision, expr(revision + 1)))
    end

    update :cache_vfs_projection do
      transaction?(false)
      require_atomic?(true)
      accept([:vfs_md_size, :vfs_md_blake3, :vfs_content_empty])
    end

    read :list_children do
      pagination(keyset?: true, max_page_size: 200, countable: false, required?: false)
    end

    read :list_roots do
      pagination(keyset?: true, max_page_size: 200, countable: false, required?: false)
    end

    read :search do
      argument(:required_action, :atom,
        allow_nil?: false,
        default: :node_view,
        constraints: [one_of: [:node_view, :node_edit]]
      )
    end
  end

  @type t :: %__MODULE__{}
end
