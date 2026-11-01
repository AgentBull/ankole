defmodule Ankole.Conversations.DeliveryAttachment do
  @moduledoc "An ordered Delivery attachment that pins bytes while delivery can still run."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  postgres do
    table("delivery_attachments")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, primary_key?: true, allow_nil?: false)
    attribute(:binding_name, :string, primary_key?: true, allow_nil?: false)
    attribute(:outbound_key, :string, primary_key?: true, allow_nil?: false)
    attribute(:position, :integer, primary_key?: true, allow_nil?: false, constraints: [min: 0])
    attribute(:object_id, Ankole.Ash.Types.UUIDv7)
    attribute(:node_id, Ankole.Ash.Types.UUIDv7)

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      constraints: [allow_datetime?: true]
    )
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :agent_uid,
        :binding_name,
        :outbound_key,
        :position,
        :object_id,
        :node_id,
        :metadata
      ])
    end

    update :release do
      require_atomic?(true)
      accept([])
      change(set_attribute(:object_id, nil))
      change(set_attribute(:node_id, nil))
    end

    destroy :remove do
      require_atomic?(true)
    end
  end
end
