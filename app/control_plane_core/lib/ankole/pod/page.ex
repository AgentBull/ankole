defmodule Ankole.Pod.Page do
  @moduledoc "One page tree node, its document revision, and its trash state."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod, extensions: [AshJsonApi.Resource]

  json_api do
    type("pod_page")
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("pages")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:parent_id, "pages_tenant_id_parent_id_fkey"}])
    unique_index_names([{[:id], "pages_pkey"}])

    check_constraints do
      check_constraint(:type, "pages_type_check")
      check_constraint(:parent_id, "pages_private_owner")
      check_constraint(:purge_started_at, "pages_purge_state")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true, primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:parent_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:private_owner_uid, Ankole.Ash.Types.PrincipalKey, public?: true)

    attribute(:type, :atom,
      public?: true, allow_nil?: false,
      constraints: [one_of: [:doc, :database, :applet, :file]]
    )

    attribute(:title, :string,
      public?: true, allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:icon, :string, public?: true, constraints: [trim?: false, allow_empty?: true])
    attribute(:position, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:inherit_permissions, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:revision, :integer, public?: true, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:saved_from_message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:created_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:deleted_at, :utc_datetime_usec, public?: true)
    attribute(:purge_started_at, :utc_datetime_usec, public?: true)
    attribute(:created_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, public?: true, allow_nil?: false)
  end

  calculations do
    calculate(:role, :atom, expr(nil), public?: true, constraints: [one_of: [:view, :edit, :manage]])
  end

  relationships do
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
        :revision,
        :saved_from_message_id,
        :created_by,
        :deleted_at,
        :purge_started_at,
        :created_at,
        :updated_at
      ])

      validate(Ankole.Pod.Validations.PageState)
    end

    update :edit do
      accept([:title, :icon, :updated_at])
    end

    update :move do
      accept([:parent_id, :private_owner_uid, :position, :updated_at])
      validate(Ankole.Pod.Validations.PageState)
    end

    update :position do
      require_atomic?(true)
      accept([:position])
    end

    update :sharing do
      require_atomic?(true)
      accept([:inherit_permissions])
    end

    update :trash do
      require_atomic?(true)
      accept([])
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    update :restore do
      require_atomic?(true)
      change(filter(expr(not is_nil(deleted_at) and is_nil(purge_started_at))))
      accept([])
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
