defmodule Ankole.Pod.Page do
  @moduledoc "Read-only Pod projection of a Drive node and its optional Pod properties."
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:read, check: :drive_filter)
    allow(:list_children, check: :drive_filter)
    allow(:list_roots, check: :drive_filter)
    allow(:search, check: :drive_filter)
  end

  json_api do
    type("pod_page")
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("pod_page_nodes")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:name, :string, public?: true)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:is_root, :boolean, public?: true)
    attribute(:parent_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:private_owner_uid, Ankole.Ash.Types.PrincipalKey, public?: true)

    attribute(:type, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:folder, :doc, :base, :applet, :file]]
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

    attribute(:created_by, Ankole.Ash.Types.ActorRef)
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
        default: :node_view,
        constraints: [one_of: [:node_view, :node_edit]]
      )
    end
  end

  @type t :: %__MODULE__{}
end
