defmodule Ankole.Conversations.MessageAttachment do
  @moduledoc "An ordered Message attachment whose object reference freezes its bytes."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  postgres do
    table("message_attachments")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:message_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
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
      accept([:message_id, :position, :object_id, :node_id, :metadata])
    end

    destroy :remove do
      require_atomic?(true)
    end
  end
end
