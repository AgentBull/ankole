defmodule Ankole.Files.Schemas.Node do
  @moduledoc "Owns one tenant's Drive namespace, current file object and permission anchor."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Files

  postgres do
    table("drive_nodes")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:parent_id, "drive_nodes_parent_fkey"},
      {:object_id, "drive_nodes_object_fkey"},
      {:private_owner_uid, "drive_nodes_private_owner_fkey"},
      {:conversation_id, "drive_nodes_conversation_fkey"}
    ])

    check_constraints do
      check_constraint(:name, "drive_nodes_name_shape")
      check_constraint(:mode, "drive_nodes_mode")
      check_constraint(:kind, "drive_nodes_kind")
      check_constraint(:object_id, "drive_nodes_object_shape")
      check_constraint(:acl_anchor_id, "drive_nodes_acl_anchor_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:parent_id, Ankole.Ash.Types.UUIDv7)
    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:folder, :file, :doc, :base, :applet]]
    )

    attribute(:private_owner_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7)
    attribute(:inherit_permissions, :boolean, allow_nil?: false, default: true)
    attribute(:has_local_acl, :boolean, allow_nil?: false, default: false)
    attribute(:is_acl_anchor, :boolean, allow_nil?: false, generated?: true, writable?: false)
    attribute(:acl_anchor_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:parent_anchor_id, Ankole.Ash.Types.UUIDv7)
    attribute(:object_id, Ankole.Ash.Types.UUIDv7)

    attribute(:mode, :integer,
      allow_nil?: false,
      default: 0o644,
      constraints: [min: 0, max: 0o777]
    )

    attribute(:content_type, :string)
    attribute(:source, :string)
    attribute(:message_id, Ankole.Ash.Types.UUIDv7)
    attribute(:source_conversation_id, Ankole.Ash.Types.UUIDv7)
    attribute(:created_by, Ankole.Ash.Types.ActorRef)
    attribute(:deleted_at, Ankole.Ash.Types.Timestamptz)
    attribute(:purge_started_at, Ankole.Ash.Types.Timestamptz)
    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz, writable?: true)
    create_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz, writable?: true)
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
        :kind,
        :private_owner_uid,
        :conversation_id,
        :inherit_permissions,
        :has_local_acl,
        :acl_anchor_id,
        :parent_anchor_id,
        :object_id,
        :mode,
        :content_type,
        :source,
        :message_id,
        :source_conversation_id,
        :created_by,
        :deleted_at,
        :purge_started_at,
        :created_at,
        :updated_at
      ])
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
        :mode,
        :content_type,
        :source,
        :message_id,
        :source_conversation_id,
        :deleted_at,
        :purge_started_at,
        :updated_at
      ])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
