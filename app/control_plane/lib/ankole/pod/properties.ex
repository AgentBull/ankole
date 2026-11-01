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
        :saved_from_message_id,
        :children_view,
        :created_at,
        :updated_at
      ])

      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :edit do
      accept([:title, :icon, :position, :children_view, :updated_at])
      validate(Ankole.Pod.Validations.ChildrenView)
    end

    update :position do
      require_atomic?(true)
      accept([:position])
    end

    update :advance_revision do
      require_atomic?(true)
      accept([:updated_at])
      change(atomic_update(:revision, expr(revision + 1)))
    end

    destroy :remove do
      require_atomic?(true)
    end
  end
end
