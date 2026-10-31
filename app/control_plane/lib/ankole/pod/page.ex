defmodule Ankole.Pod.Page do
  @moduledoc "One page tree node, its document revision, and its trash state."
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:read, check: :pod_filter)
    allow(:list_children, check: :pod_filter)
    allow(:list_roots, check: :pod_filter)
    allow(:search, check: :pod_filter)
  end

  json_api do
    type("pod_page")
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("pages")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:parent_id, "pages_tenant_id_parent_id_fkey"},
      {:acl_anchor_id, "pages_tenant_acl_anchor_fkey"},
      {:parent_anchor_id, "pages_tenant_parent_anchor_fkey"}
    ])

    unique_index_names([{[:id], "pages_pkey"}])

    check_constraints do
      check_constraint(:type, "pages_type_check")
      check_constraint(:acl_anchor_id, "pages_acl_anchor_shape")
      check_constraint(:parent_id, "pages_private_owner")
      check_constraint(:purge_started_at, "pages_purge_state")
      check_constraint(:children_view, "pages_children_view_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:parent_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:private_owner_uid, Ankole.Ash.Types.PrincipalKey, public?: true)

    attribute(:type, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:doc, :base, :applet, :file]]
    )

    attribute(:title, :string,
      public?: true,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true, max_length: 255]
    )

    attribute(:icon, :string, public?: true, constraints: [trim?: false, allow_empty?: true])
    attribute(:position, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:inherit_permissions, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:has_local_acl, :boolean, allow_nil?: false, default: false)
    attribute(:is_acl_anchor, :boolean, writable?: false)
    attribute(:acl_anchor_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:parent_anchor_id, Ankole.Ash.Types.UUIDv7)

    attribute(:revision, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:saved_from_message_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:children_view, Ankole.Ash.Types.JSONMap,
      public?: true,
      allow_nil?: false,
      default: %{},
      constraints: [max_bytes: 1024]
    )

    attribute(:created_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:deleted_at, Ankole.Ash.Types.Timestamptz, public?: true)
    attribute(:purge_started_at, Ankole.Ash.Types.Timestamptz, public?: true)
    attribute(:created_at, Ankole.Ash.Types.Timestamptz, public?: true, allow_nil?: false)
    attribute(:updated_at, Ankole.Ash.Types.Timestamptz, public?: true, allow_nil?: false)
  end

  calculations do
    calculate(:actions, {:array, :atom}, expr(nil),
      public?: true,
      constraints: [
        items: [
          one_of: [:page_view, :page_write_records, :page_edit, :page_manage, :page_comment]
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
  end

  actions do
    defaults([:read])

    read :list_children do
      pagination(keyset?: true, max_page_size: 200, countable: false, required?: false)
    end

    read :list_roots do
      pagination(keyset?: true, max_page_size: 200, countable: false, required?: false)
    end

    read :search do
      argument(:required_action, :atom,
        allow_nil?: false,
        default: :page_view,
        constraints: [one_of: [:page_view, :page_edit]]
      )
    end

    create :create_in_tx do
      accept([
        :id,
        :parent_id,
        :private_owner_uid,
        :type,
        :title,
        :icon,
        :position,
        :inherit_permissions,
        :has_local_acl,
        :acl_anchor_id,
        :parent_anchor_id,
        :revision,
        :saved_from_message_id,
        :children_view,
        :created_by,
        :deleted_at,
        :purge_started_at,
        :created_at,
        :updated_at
      ])

      validate(Ankole.Pod.Validations.PageState)
      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :edit do
      accept([:title, :icon, :children_view, :updated_at])
      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :move do
      accept([
        :parent_id,
        :private_owner_uid,
        :position,
        :updated_at,
        :acl_anchor_id,
        :parent_anchor_id
      ])

      validate(Ankole.Pod.Validations.PageState)
    end

    update :position do
      require_atomic?(true)
      accept([:position])
    end

    update :sharing do
      require_atomic?(true)
      accept([:inherit_permissions, :acl_anchor_id, :parent_anchor_id])
    end

    update :anchor do
      require_atomic?(true)
      accept([:has_local_acl, :acl_anchor_id, :parent_anchor_id])
    end

    update :trash do
      require_atomic?(true)
      accept([:deleted_at, :acl_anchor_id, :parent_anchor_id])
    end

    update :restore do
      require_atomic?(true)
      change(filter(expr(not is_nil(deleted_at) and is_nil(purge_started_at))))
      accept([:acl_anchor_id, :parent_anchor_id])
      change(set_attribute(:deleted_at, nil))
    end

    update :begin_purge do
      require_atomic?(true)
      change(filter(expr(not is_nil(deleted_at))))
      accept([])
      change(set_attribute(:purge_started_at, &DateTime.utc_now/0))
    end

    update :advance_revision do
      require_atomic?(true)
      accept([:updated_at])
      change(atomic_update(:revision, expr(revision + 1)))
    end

    destroy :purge do
      require_atomic?(true)
      change(filter(expr(not exists(children, true))))
    end
  end

  @type t :: %__MODULE__{}
end
