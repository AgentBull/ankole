defmodule Ankole.Pod.Page do
  @moduledoc "One page tree node, its document revision, and its trash state."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod.Domain

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
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:parent_id, Ankole.Ash.Types.UUIDv7)
    attribute(:private_owner_uid, Ankole.Ash.Types.PrincipalKey)

    attribute(:type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:doc, :database, :applet, :file]]
    )

    attribute(:title, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:icon, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:position, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:inherit_permissions, :boolean, allow_nil?: false, default: true)
    attribute(:revision, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:saved_from_message_id, Ankole.Ash.Types.UUIDv7)
    attribute(:created_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:deleted_at, :utc_datetime_usec)
    attribute(:purge_started_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  calculations do
    calculate(:role, :string, expr(nil))
  end

  relationships do
    has_many :children, __MODULE__ do
      source_attribute(:id)
      destination_attribute(:parent_id)
    end
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      transaction?(false)

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

    in_tx_update :edit do
      accept([:title, :icon, :updated_at])
    end

    in_tx_update :move do
      accept([:parent_id, :private_owner_uid, :position, :updated_at])
      validate(Ankole.Pod.Validations.PageState)
    end

    atomic_in_tx_update :position do
      accept([:position])
    end

    atomic_in_tx_update :sharing do
      accept([:inherit_permissions])
    end

    atomic_in_tx_update :trash do
      accept([])
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    atomic_in_tx_update :restore do
      change(filter(expr(not is_nil(deleted_at) and is_nil(purge_started_at))))
      accept([])
      change(set_attribute(:deleted_at, nil))
    end

    atomic_in_tx_update :begin_purge do
      change(filter(expr(not is_nil(deleted_at))))
      accept([])
      change(set_attribute(:purge_started_at, &DateTime.utc_now/0))
    end

    atomic_in_tx_update :advance_revision do
      accept([:updated_at])
      change(atomic_update(:revision, expr(revision + 1)))
    end

    destroy :purge do
      transaction?(false)
      require_atomic?(true)
      change(filter(expr(not exists(children, true))))
    end
  end

  @type t :: %__MODULE__{}
end
